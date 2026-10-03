using System;
using System.Collections;
using internal FormatCore;

namespace FormatCore;

/// Encodes UTF-8 text into another encoding (XmlBeef's XmlEncoder): the reverse of Decoder, for writers
/// that write bytes. What to do with a character the encoding cannot hold (a character reference, a
/// replacement, an error) is the format's: Encode stops there and says where.
internal static class Encoder
{
	/// @brief Append `text` (valid UTF-8) to `output` in `encoding`, up to the first character the
	/// encoding cannot hold.
	/// @param text The text.
	/// @param encoding The encoding (Custom holds nothing: a converter only reads).
	/// @param output Receives the bytes.
	/// @return The offset in `text` of the first character the encoding cannot hold, or -1.
	public static int Encode(StringView text, TextEncoding encoding, List<uint8> output)
	{
		if (encoding == .Utf8)
		{
			output.AddRange(Span<uint8>((uint8*)text.Ptr, text.Length));
			return -1;
		}
		if (encoding == .Custom)
			return text.IsEmpty ? -1 : 0;
		uint16* table = encoding >= .Ibm866 ? SingleByteTables.Get(encoding) : null;
		int i = 0;
		while (i < text.Length)
		{
			uint8 b = (uint8)text[i];
			uint32 c;
			int length;
			if (b < 0x80)
			{
				c = b;
				length = 1;
			}
			else
				c = (uint32)Utf8.Decode(text.Ptr, i, out length);
			switch (encoding)
			{
			case .Utf16LE, .Utf16BE:
				if (c >= 0x10000)
				{
					uint32 v = c - 0x10000;
					Put16(output, 0xD800 | (v >> 10), encoding == .Utf16BE);
					Put16(output, 0xDC00 | (v & 0x3FF), encoding == .Utf16BE);
				}
				else
					Put16(output, c, encoding == .Utf16BE);
			case .Utf32LE, .Utf32BE:
				if (encoding == .Utf32BE)
				{
					output.Add((uint8)(c >> 24));
					output.Add((uint8)(c >> 16));
					output.Add((uint8)(c >> 8));
					output.Add((uint8)c);
				}
				else
				{
					output.Add((uint8)c);
					output.Add((uint8)(c >> 8));
					output.Add((uint8)(c >> 16));
					output.Add((uint8)(c >> 24));
				}
			case .Ascii:
				if (c >= 0x80)
					return i;
				output.Add((uint8)c);
			default:
				// Latin-1 (no table: bytes are code points) and the single-byte tables
				if (c < 0x80)
					output.Add((uint8)c);
				else if (table == null)
				{
					if (c > 0xFF)
						return i;
					output.Add((uint8)c);
				}
				else
				{
					int index = IndexOf(table, c);
					if (index < 0)
						return i;
					output.Add((uint8)(0x80 + index));
				}
			}
			i += length;
		}
		return -1;
	}

	/// @brief Whether `encoding` can hold the character `c`.
	/// @param c The character.
	/// @param encoding The encoding.
	/// @return Whether it can.
	public static bool CanEncode(char32 c, TextEncoding encoding)
	{
		uint32 cp = (uint32)c;
		if (cp < 0x80)
			return encoding != .Custom;
		switch (encoding)
		{
		case .Utf8, .Utf16LE, .Utf16BE, .Utf32LE, .Utf32BE:
			return true;
		case .Ascii, .Custom:
			return false;
		case .Latin1:
			return cp <= 0xFF;
		default:
			return IndexOf(SingleByteTables.Get(encoding), cp) >= 0;
		}
	}

	static int IndexOf(uint16* table, uint32 cp)
	{
		if (cp > 0xFFFF)
			return -1;
		for (int k < 128)
		{
			if (table[k] == cp)
				return k;
		}
		return -1;
	}

	static void Put16(List<uint8> output, uint32 unit, bool bigEndian)
	{
		if (bigEndian)
		{
			output.Add((uint8)(unit >> 8));
			output.Add((uint8)unit);
		}
		else
		{
			output.Add((uint8)unit);
			output.Add((uint8)(unit >> 8));
		}
	}
}
