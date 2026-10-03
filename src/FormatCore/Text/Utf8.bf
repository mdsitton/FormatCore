using System;
using internal FormatCore;

namespace FormatCore;

/// UTF-8 validation, decoding and encoding, code point counting, and the naive line locator: the
/// copies in TomlChar, KdlChar, XmlChar and JsonChar, merged. Validation follows Unicode §3.9 table
/// 3-7 (overlongs, encoded surrogates and code points above U+10FFFF are errors), JsonBeef's version.
internal static class Utf8
{
	/// @brief The length of the UTF-8 sequence that starts with `leadChar`: 1-4, or 0 for a byte that
	/// cannot start one (by its bit pattern only; FindInvalid checks the rest).
	/// @param leadChar The first byte.
	/// @return The length.
	[Inline]
	public static int SequenceLength(char8 leadChar)
	{
		uint8 lead = (uint8)leadChar;
		if (lead < 0x80) return 1;
		if ((lead & 0xE0) == 0xC0) return 2;
		if ((lead & 0xF0) == 0xE0) return 3;
		if ((lead & 0xF8) == 0xF0) return 4;
		return 0;
	}

	/// @brief Decode the code point at `text[pos]` from input already checked as UTF-8.
	/// @param text The bytes.
	/// @param pos Byte offset of the lead byte.
	/// @param length Receives the sequence length in bytes.
	/// @return The code point (U+FFFD for a byte that starts no sequence, with length 1).
	public static char32 Decode(char8* text, int pos, out int length)
	{
		uint8* data = (uint8*)text;
		uint8 b0 = data[pos];
		if (b0 < 0x80)
		{
			length = 1;
			return (char32)b0;
		}
		length = SequenceLength((char8)b0);
		switch (length)
		{
		case 2:
			return (char32)(((uint32)(b0 & 0x1F) << 6) | (uint32)(data[pos + 1] & 0x3F));
		case 3:
			return (char32)(((uint32)(b0 & 0x0F) << 12) | ((uint32)(data[pos + 1] & 0x3F) << 6) | (uint32)(data[pos + 2] & 0x3F));
		case 4:
			return (char32)(((uint32)(b0 & 0x07) << 18) | ((uint32)(data[pos + 1] & 0x3F) << 12) |
				((uint32)(data[pos + 2] & 0x3F) << 6) | (uint32)(data[pos + 3] & 0x3F));
		default:
			length = 1;
			return (char32)0xFFFD;
		}
	}

	/// @brief Encode a code point as UTF-8 at `dst`, which has room for 4 bytes.
	/// @param dst Where to write.
	/// @param cp The code point (0-0x10FFFF, not a surrogate).
	/// @return The bytes written.
	[Inline]
	public static int Encode(char8* dst, uint32 cp)
	{
		if (cp < 0x80)
		{
			dst[0] = (char8)cp;
			return 1;
		}
		if (cp < 0x800)
		{
			dst[0] = (char8)(0xC0 | (cp >> 6));
			dst[1] = (char8)(0x80 | (cp & 0x3F));
			return 2;
		}
		if (cp < 0x10000)
		{
			dst[0] = (char8)(0xE0 | (cp >> 12));
			dst[1] = (char8)(0x80 | ((cp >> 6) & 0x3F));
			dst[2] = (char8)(0x80 | (cp & 0x3F));
			return 3;
		}
		dst[0] = (char8)(0xF0 | (cp >> 18));
		dst[1] = (char8)(0x80 | ((cp >> 12) & 0x3F));
		dst[2] = (char8)(0x80 | ((cp >> 6) & 0x3F));
		dst[3] = (char8)(0x80 | (cp & 0x3F));
		return 4;
	}

	/// @brief Encode a code point as UTF-8 and append it, in one buffer call (corlib's Append(char8) is
	/// not inlined).
	/// @param result The string to append to.
	/// @param cp The code point (0-0x10FFFF, not a surrogate).
	public static void Encode(String result, uint32 cp)
	{
		// One branch per length (XmlBeef's shape: sizing first and then branching again in the pointer
		// version cost character references 0.3%)
		if (cp < 0x80)
		{
			result.Append((char8)cp);
		}
		else if (cp < 0x800)
		{
			char8* p = result.PrepareBuffer(2);
			p[0] = (char8)(0xC0 | (cp >> 6));
			p[1] = (char8)(0x80 | (cp & 0x3F));
		}
		else if (cp < 0x10000)
		{
			char8* p = result.PrepareBuffer(3);
			p[0] = (char8)(0xE0 | (cp >> 12));
			p[1] = (char8)(0x80 | ((cp >> 6) & 0x3F));
			p[2] = (char8)(0x80 | (cp & 0x3F));
		}
		else
		{
			char8* p = result.PrepareBuffer(4);
			p[0] = (char8)(0xF0 | (cp >> 18));
			p[1] = (char8)(0x80 | ((cp >> 12) & 0x3F));
			p[2] = (char8)(0x80 | ((cp >> 6) & 0x3F));
			p[3] = (char8)(0x80 | (cp & 0x3F));
		}
	}

	/// @brief Whether the input starts with a UTF-8 byte order mark.
	/// @param data The input.
	/// @param length The bytes available (a BOM needs 3).
	/// @return Whether it does.
	[Inline]
	public static bool StartsWithBom(char8* data, int length)
	{
		return length >= 3 && (uint8)data[0] == 0xEF && (uint8)data[1] == 0xBB && (uint8)data[2] == 0xBF;
	}

	/// The second byte's range for a lead byte (table 3-7): what rules out overlongs, surrogates and
	/// code points above U+10FFFF.
	[Inline]
	static void SecondByteRange(uint8 lead, out uint8 low, out uint8 high)
	{
		low = 0x80;
		high = 0xBF;
		if (lead == 0xE0) low = 0xA0;
		else if (lead == 0xED) high = 0x9F;
		else if (lead == 0xF0) low = 0x90;
		else if (lead == 0xF4) high = 0x8F;
	}

	/// @brief Find the first ill-formed UTF-8 sequence, or code point the policy bans, in
	/// `text[from ..< to]`. A sequence cut by `to` is an error: streams pass only complete sequences
	/// (`CompleteSequencesEnd`) until their input ends. Plain words are skipped 32 and 8 bytes at a time.
	/// Errors are reported at the sequence's lead byte, with `length` covering the offending bytes, in
	/// JsonBeef's wording (the bytes are named).
	/// @param text The input (offsets index it).
	/// @param from The first byte to check (after any BOM).
	/// @param to The end of the range.
	/// @param message Receives the error message.
	/// @param kind Receives InvalidUtf8 or InvalidChar (a code point the policy bans).
	/// @param length Receives the length of the offending bytes.
	/// @return The offset of the first error, or -1.
	public static int FindInvalid<TText>(char8* text, int from, int to, String message, out InputErrorKind kind, out int length)
		where TText : ITextPolicy
	{
		uint8* data = (uint8*)text;
		kind = .InvalidUtf8;
		length = 1;
		int i = from;
		while (i < to)
		{
			if (i + 32 <= to && TText.IsPlainBlock(Swar.Load64(text + i), Swar.Load64(text + i + 8), Swar.Load64(text + i + 16), Swar.Load64(text + i + 24)))
			{
				i += 32;
				continue;
			}
			if (i + 8 <= to && TText.IsPlainWord(Swar.Load64(text + i)))
			{
				i += 8;
				continue;
			}
			int limit = Math.Min(i + 8, to);
			while (i < limit)
			{
				uint8 b = data[i];
				if (b < 0x80)
				{
					if (!TText.AllowsAscii(b))
					{
						kind = .InvalidChar;
						TText.AppendBanned(message, b);
						return i;
					}
					i++;
					continue;
				}
				if (i + 4 <= to)
				{
					// The common 2- and 3-byte sequences from one word (ValidSequenceLength's test); the others,
					// and every error, take the exact path below
					uint32 word = Swar.Load32(text + i);
					int common = 0;
					if (b >= 0xC2 && b < 0xE0 && (word & 0xC000) == 0x8000)
						common = 2;
					else if (b >= 0xE1 && b < 0xF0 && b != 0xED && (word & 0xC0C000) == 0x808000)
						common = 3;
					if (common != 0 && (!TText.BansCodePoints || TText.AllowsCodePoint((uint32)Decode(text, i, ?))))
					{
						i += common;
						continue;
					}
				}
				int seqLen = SequenceLength((char8)b);
				if (seqLen == 0 || b == 0xC0 || b == 0xC1 || b > 0xF4)
				{
					message.AppendF("The byte 0x{:X2} is not valid UTF-8 ", b);
					if ((b & 0xC0) == 0x80)
						message.Append("(a continuation byte without a lead byte)");
					else if (b < 0xC2)
						message.Append("(it can only start an overlong encoding)");
					else
						message.Append("(it never appears in UTF-8)");
					return i;
				}
				if (i + seqLen > to)
				{
					message.AppendF("The UTF-8 sequence starting with 0x{:X2} is cut off by the end of the input", b);
					length = to - i;
					return i;
				}
				SecondByteRange(b, let low, let high);
				uint8 b1 = data[i + 1];
				if (b1 < low || b1 > high)
				{
					AppendSequenceError(message, b, b1);
					length = 2;
					return i;
				}
				for (int j = 2; j < seqLen; j++)
				{
					if ((data[i + j] & 0xC0) != 0x80)
					{
						message.AppendF("The UTF-8 sequence starting with 0x{:X2} is cut off by 0x{:X2}", b, data[i + j]);
						length = j + 1;
						return i;
					}
				}
				if (TText.BansCodePoints)
				{
					uint32 cp = (uint32)Decode(text, i, ?);
					if (!TText.AllowsCodePoint(cp))
					{
						kind = .InvalidChar;
						length = seqLen;
						TText.AppendBanned(message, cp);
						return i;
					}
				}
				// A sequence may end past `limit`: the word checks resume after it
				i += seqLen;
			}
		}
		return -1;
	}

	static void AppendSequenceError(String message, uint8 lead, uint8 next)
	{
		if ((next & 0xC0) != 0x80)
			message.AppendF("The UTF-8 sequence starting with 0x{:X2} is cut off by 0x{:X2}", lead, next);
		else if (lead == 0xED)
			message.AppendF("The bytes 0x{:X2} 0x{:X2} encode a surrogate (U+D800-U+DFFF), which is not valid UTF-8", lead, next);
		else if (lead == 0xF4)
			message.AppendF("The bytes 0x{:X2} 0x{:X2} encode a code point above U+10FFFF, which is not valid UTF-8", lead, next);
		else
			message.AppendF("The bytes 0x{:X2} 0x{:X2} are an overlong UTF-8 encoding", lead, next);
	}

	/// @brief The length of the well-formed UTF-8 sequence at `p[i]` (a lead byte ≥ 0x80) within
	/// `p[i ..< length]`, or 0 if it is ill-formed or cut off (table 3-7). For scanners that validate
	/// as they go (JsonBeef's string scan).
	/// @param p The bytes.
	/// @param i The lead byte's offset.
	/// @param length The end of the available bytes.
	/// @return 2-4, or 0.
	[Inline]
	public static int ValidSequenceLength(char8* p, int i, int length)
	{
		uint8 b = (uint8)p[i];
		if (i + 4 <= length)
		{
			// The common sequences from one word: the lead's length, the continuation bytes' tags, and the
			// second byte's range for the leads that restrict it
			uint32 word = Swar.Load32(p + i);
			if (b >= 0xC2 && b < 0xE0)
				return (word & 0xC000) == 0x8000 ? 2 : 0;
			if (b >= 0xE1 && b < 0xF0 && b != 0xED)
				return (word & 0xC0C000) == 0x808000 ? 3 : 0;
		}
		if (b < 0xC2 || b > 0xF4)
			return 0;
		int seqLength = b < 0xE0 ? 2 : b < 0xF0 ? 3 : 4;
		if (i + seqLength > length)
			return 0;
		SecondByteRange(b, let low, let high);
		uint8 b1 = (uint8)p[i + 1];
		if (b1 < low || b1 > high)
			return 0;
		for (int j = 2; j < seqLength; j++)
		{
			if (((uint8)p[i + j] & 0xC0) != 0x80)
				return 0;
		}
		return seqLength;
	}

	/// @brief The length of the maximal ill-formed subpart at `p[i]` (a byte ≥ 0x80 that starts no
	/// well-formed sequence within `p[i ..< length]`): the lead byte and the continuation bytes after it
	/// that could still have been part of a sequence (Unicode §3.9, "U+FFFD Substitution of Maximal
	/// Subparts"). One U+FFFD replaces each: `C0 AF` is two subparts, `ED A0 80` three, `E2 82` one.
	/// @param p The bytes.
	/// @param i The subpart's first byte.
	/// @param length The end of the available bytes.
	/// @return 1-3.
	public static int MaximalSubpartLength(char8* p, int i, int length)
	{
		uint8 b = (uint8)p[i];
		if (b < 0xC2 || b > 0xF4)
			return 1;
		int seqLength = b < 0xE0 ? 2 : b < 0xF0 ? 3 : 4;
		SecondByteRange(b, let low, let high);
		int n = 1;
		while (n < seqLength && i + n < length)
		{
			uint8 c = (uint8)p[i + n];
			if (n == 1 ? (c < low || c > high) : (c & 0xC0) != 0x80)
				break;
			n++;
		}
		return n;
	}

	/// @brief The end of the complete UTF-8 sequences in `text[from ..< to]`: `to`, or the start of a
	/// sequence cut off by `to` (a stream validates it once the rest arrives).
	/// @param text The bytes.
	/// @param from The start of the range.
	/// @param to The end of the range.
	/// @return The end of the complete sequences.
	public static int CompleteSequencesEnd(char8* text, int from, int to)
	{
		for (int back = 1; back <= 3; back++)
		{
			int p = to - back;
			if (p < from)
				break;
			uint8 b = (uint8)text[p];
			if ((b & 0xC0) == 0x80)
				continue;
			// A lead byte (or ASCII): cut if its sequence runs past `to`; invalid bytes are FindInvalid's
			int seqLen = SequenceLength((char8)b);
			return (seqLen > 0 && p + seqLen > to) ? p : to;
		}
		return to;
	}

	/// @brief The number of code points in `text[from ..< to]`: its bytes that are not continuation
	/// bytes (10xxxxxx), counted 8 at a time.
	/// @param text The bytes.
	/// @param from The start of the range.
	/// @param to The end of the range.
	/// @return The count.
	public static int CountCodePoints(char8* text, int from, int to)
	{
		int count = 0;
		int p = from;
		while (p + 8 <= to)
		{
			uint64 word = Swar.Load64(text + p);
			uint64 continuation = word & ~(word << 1) & Swar.High;
			count += continuation == 0 ? 8 : 8 - Swar.CountHighBits(continuation);
			p += 8;
		}
		while (p < to)
		{
			if (((uint8)text[p] & 0xC0) != 0x80)
				count++;
			p++;
		}
		return count;
	}

	/// @brief The byte index of the first noncharacter in the well-formed UTF-8 `text` (U+FDD0-U+FDEF,
	/// and U+xFFFE and U+xFFFF in every plane), or -1. Only lead bytes EF-F4 can start one.
	/// @param text The text.
	/// @return The index, or -1.
	public static int FindNoncharacter(StringView text)
	{
		char8* p = text.Ptr;
		int length = text.Length;
		for (int i < length)
		{
			uint8 b = (uint8)p[i];
			if (b < 0xEF)
				continue;
			if (b == 0xEF && i + 2 < length)
			{
				uint8 b1 = (uint8)p[i + 1];
				uint8 b2 = (uint8)p[i + 2];
				// EF B7 90-AF: U+FDD0-U+FDEF; EF BF BE-BF: U+FFFE, U+FFFF
				if ((b1 == 0xB7 && b2 >= 0x90 && b2 <= 0xAF) || (b1 == 0xBF && b2 >= 0xBE))
					return i;
			}
			else if (b >= 0xF0 && b <= 0xF4 && i + 3 < length)
			{
				// U+nFFFE, U+nFFFF: xx 8F|9F|AF|BF BF BE|BF
				if (((uint8)p[i + 1] & 0x0F) == 0x0F && (uint8)p[i + 2] == 0xBF && (uint8)p[i + 3] >= 0xBE)
					return i;
			}
		}
		return -1;
	}

	/// @brief The byte length of an LF, CR or CRLF (one newline) at `text[pos]`, or 0.
	/// @param text The bytes.
	/// @param pos The offset (`pos < end`).
	/// @param end The end of the available bytes.
	/// @return 0-2.
	[Inline]
	public static int AsciiNewlineLength(char8* text, int pos, int end)
	{
		char8 c = text[pos];
		if (c == '\n')
			return 1;
		if (c != '\r')
			return 0;
		return (pos + 1 < end && text[pos + 1] == '\n') ? 2 : 1;
	}

	/// @brief The 1-based line and column (in code points) of byte `offset`, counting the policy's
	/// newlines (CRLF as one), one character at a time: the reference LineCounter and LineIndex are
	/// tested against, and the fallback for a position behind a counter. A leading BOM takes no column;
	/// an offset inside a multi-byte newline (on the LF of a CRLF) is on the line the newline ends.
	/// @param input The text.
	/// @param offset A byte offset into it (clamped to its length).
	/// @param line Receives the line.
	/// @param column Receives the column.
	public static void LineAndColumn<TText>(StringView input, int offset, out int line, out int column) where TText : ITextPolicy
	{
		int end = Math.Min(offset, input.Length);
		int i = StartsWithBom(input.Ptr, input.Length) ? 3 : 0;
		line = 1;
		column = 1;
		while (i < end)
		{
			int newline = TText.NewlineLength(input.Ptr, i, input.Length);
			if (i + newline > end)
			{
				column++;
				break;
			}
			if (newline > 0)
			{
				i += newline;
				line++;
				column = 1;
				continue;
			}
			i += Math.Max(SequenceLength(input[i]), 1);
			column++;
		}
	}
}
