using System;
using internal FormatCore;

namespace FormatCore;

/// Decodes one encoding into UTF-8, a piece at a time (XmlBeef's XmlDecoder): the whole input at once
/// for memory, or as a stream's bytes arrive (a code unit cut off at a piece's end waits for the next
/// piece). UTF-8 is copied as is (validation is the text policy's); US-ASCII rejects bytes above 0x7F;
/// Latin-1 and the tables decode a byte at a time; UTF-16 copies runs of ASCII four units per 8-byte
/// load into one 4-byte store, and checks surrogates.
internal struct Decoder
{
	TextEncoding mEncoding;
	uint16* mTable;

	/// @brief A decoder for `encoding` (not Custom: a converter's output is UTF-8).
	/// @param encoding The encoding.
	public this(TextEncoding encoding)
	{
		mEncoding = encoding;
		mTable = encoding >= .Ibm866 ? SingleByteTables.Get(encoding) : null;
	}

	/// @brief The encoding.
	public TextEncoding Encoding => mEncoding;

	/// @brief The most UTF-8 bytes one input byte can become (a worst-case output size is
	/// `length * MaxExpansion + 8`).
	public int MaxExpansion
	{
		get
		{
			switch (mEncoding)
			{
			case .Utf8, .Ascii, .Utf32LE, .Utf32BE, .Custom: return 1;
			case .Latin1: return 2;
			default: return 3;
			}
		}
	}

	/// @brief Decode `src` into `dst` as far as both allow: stops at a code unit cut off at the end of
	/// `src` (unless `final`, where that is an error) or when `dst` has no room for the next one (4 bytes).
	/// @param src The input.
	/// @param srcLength Its length.
	/// @param final Whether `src` ends the input.
	/// @param dst The output.
	/// @param dstCapacity Its room.
	/// @param consumed Receives how many input bytes were decoded.
	/// @param produced Receives how many output bytes were written.
	/// @param error Receives the message when the input is invalid in the encoding (`src[consumed]` is
	/// where).
	/// @return Whether it was valid (as far as it was decoded).
	public bool Decode(uint8* src, int srcLength, bool final, uint8* dst, int dstCapacity, out int consumed, out int produced, out StringView error)
	{
		error = default;
		consumed = 0;
		produced = 0;
		int i = 0;
		int w = 0;
		defer
		{
			consumed = i;
			produced = w;
		}
		switch (mEncoding)
		{
		case .Utf8, .Custom:
			int count = Math.Min(srcLength, dstCapacity);
			Internal.MemCpy(dst, src, count);
			i = count;
			w = count;
			return true;
		case .Ascii:
			int count = Math.Min(srcLength, dstCapacity);
			while (i < count)
			{
				if (src[i] >= 0x80)
				{
					error = "A byte above 0x7F in US-ASCII";
					return false;
				}
				dst[w++] = src[i++];
			}
			return true;
		case .Utf16LE, .Utf16BE, .Utf32LE, .Utf32BE:
			return DecodeWide(src, srcLength, final, dst, dstCapacity, ref i, ref w, out error);
		default:
			// Latin-1 and the tables: a byte at a time, ASCII copied
			while (i < srcLength && w + 4 <= dstCapacity)
			{
				uint8 c = src[i];
				if (c < 0x80)
				{
					dst[w++] = c;
					i++;
					continue;
				}
				uint32 cp = mTable != null ? mTable[c - 0x80] : c;
				if (cp == 0)
				{
					error = "A byte that the encoding does not define";
					return false;
				}
				w += Utf8.Encode((char8*)dst + w, cp);
				i++;
			}
			return true;
		}
	}

	bool DecodeWide(uint8* b, int n, bool final, uint8* dst, int dstCapacity, ref int i, ref int w, out StringView error)
	{
		error = default;
		bool sixteen = mEncoding == .Utf16LE || mEncoding == .Utf16BE;
		int unit = sixteen ? 2 : 4;
		while (i + unit <= n && w + 4 <= dstCapacity)
		{
			if (sixteen)
			{
				// Runs of ASCII, four units into one 4-byte store, the bounds checked once per run
				int words = Math.Min((n - i) >> 3, (dstCapacity - w - 4) >> 2);
				int k = 0;
				if (mEncoding == .Utf16LE)
				{
					while (k < words)
					{
						uint64 word = Swar.Load64((char8*)b + i + k * 8);
						if ((word & 0xFF80FF80FF80FF80UL) != 0)
							break;
						*(uint32*)(dst + w + k * 4) = (uint32)(word & 0xFF) | (uint32)((word >> 8) & 0xFF00) | (uint32)((word >> 16) & 0xFF0000) | (uint32)((word >> 24) & 0xFF000000);
						k++;
					}
				}
				else
				{
					while (k < words)
					{
						uint64 word = Swar.Load64((char8*)b + i + k * 8);
						if ((word & 0x80FF80FF80FF80FFUL) != 0)
							break;
						*(uint32*)(dst + w + k * 4) = (uint32)((word >> 8) & 0xFF) | (uint32)((word >> 16) & 0xFF00) | (uint32)((word >> 24) & 0xFF0000) | (uint32)((word >> 32) & 0xFF000000);
						k++;
					}
				}
				i += k * 8;
				w += k * 4;
				if (i + unit > n)
					break;
			}
			uint32 cp;
			switch (mEncoding)
			{
			case .Utf16LE:
				cp = (uint32)b[i] | ((uint32)b[i + 1] << 8);
			case .Utf16BE:
				cp = ((uint32)b[i] << 8) | (uint32)b[i + 1];
			case .Utf32LE:
				cp = (uint32)b[i] | ((uint32)b[i + 1] << 8) | ((uint32)b[i + 2] << 16) | ((uint32)b[i + 3] << 24);
			default:
				cp = ((uint32)b[i] << 24) | ((uint32)b[i + 1] << 16) | ((uint32)b[i + 2] << 8) | (uint32)b[i + 3];
			}
			if (sixteen && cp >= 0xD800 && cp <= 0xDBFF)
			{
				// A high surrogate: the low one must follow (wait for it if it is not here yet)
				if (i + 4 > n)
				{
					if (!final)
						return true;
					error = "A UTF-16 high surrogate without its low surrogate";
					return false;
				}
				uint32 low = mEncoding == .Utf16LE ? ((uint32)b[i + 2] | ((uint32)b[i + 3] << 8)) : (((uint32)b[i + 2] << 8) | (uint32)b[i + 3]);
				if (low < 0xDC00 || low > 0xDFFF)
				{
					error = "A UTF-16 high surrogate without its low surrogate";
					return false;
				}
				cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
				i += 4;
			}
			else if (cp >= 0xD800 && cp <= 0xDFFF)
			{
				error = sixteen ? "A UTF-16 low surrogate without its high surrogate" : "A surrogate code point in UTF-32";
				return false;
			}
			else if (cp > 0x10FFFF)
			{
				error = "A UTF-32 code unit beyond U+10FFFF";
				return false;
			}
			else
				i += unit;
			w += Utf8.Encode((char8*)dst + w, cp);
		}
		if (final && i < n && i + unit > n && w + 4 <= dstCapacity)
		{
			error = sixteen ? "The input ends in the middle of a UTF-16 code unit" : "The input ends in the middle of a UTF-32 code unit";
			return false;
		}
		return true;
	}

	/// @brief The message for a decoding error: the decoder's own for UTF-16 and UTF-32, else the byte
	/// at fault named with the encoding (`The byte 0xAA is not defined in the encoding `windows-1253``).
	/// @param message The string to append to.
	/// @param error The decoder's message.
	/// @param encoding The encoding.
	/// @param declared The encoding's name as the input declared it (empty: the encoding's own name).
	/// @param badByte The byte at fault (`src[consumed]`).
	public static void AppendError(String message, StringView error, TextEncoding encoding, StringView declared, uint8 badByte)
	{
		if (!encoding.IsSingleByte)
		{
			message.Append(error);
			return;
		}
		message.AppendF("The byte 0x{:X2} is not defined in the encoding `{}`", badByte, declared.IsEmpty ? encoding.Name : declared);
	}
}
