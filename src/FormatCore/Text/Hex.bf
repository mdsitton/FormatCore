using System;
using internal FormatCore;

namespace FormatCore;

/// Hex digits in and out, and the code point names error messages use (four identical copies in the
/// siblings, plus JsonBeef's table-driven Hex4).
internal static class Hex
{
	/// Hex digit values by byte, 255 for anything else. A constant table: no static initializer runs.
	const uint8[256] cValues = MakeValues();

	[Comptime]
	static uint8[256] MakeValues()
	{
		uint8[256] table = ?;
		for (int i < 256)
			table[i] = DigitValue((char8)i);
		return table;
	}

	/// @brief The value of a hex digit, or 255 if `c` is not one.
	/// @param c The character.
	/// @return 0-15, or 255.
	[Inline]
	public static uint8 DigitValue(char8 c)
	{
		uint32 ci = (uint8)c;
		uint32 result = ci - (uint32)'0';
		if (result <= 9)
			return (uint8)result;
		// 'A' | 0x20 == 'a'
		result = (ci | 0x20) - (uint32)'a';
		if (result <= 5)
			return (uint8)(result + 10);
		return 255;
	}

	/// @brief The value of the four hex digits at `p` (which must be readable), or a value above 0xFFFF
	/// if one is not a hex digit: four table loads and one test (a `\u` escape's digits).
	/// @param p The first digit.
	/// @return 0-0xFFFF, or more for an error.
	[Inline]
	public static uint32 Digits4(char8* p)
	{
		uint32 a = cValues[(uint8)p[0]];
		uint32 b = cValues[(uint8)p[1]];
		uint32 c = cValues[(uint8)p[2]];
		uint32 d = cValues[(uint8)p[3]];
		if ((a | b | c | d) > 15)
			return 0x10000;
		return (a << 12) | (b << 8) | (c << 4) | d;
	}

	/// @brief Append `value` in uppercase hex with at least `minDigits` digits.
	/// @param output The string to append to.
	/// @param value The value.
	/// @param minDigits The minimum number of digits (zero-padded).
	public static void Append(String output, uint32 value, int minDigits)
	{
		int digits = 1;
		while (digits < 8 && (value >> (4 * digits)) != 0)
			digits++;
		digits = Math.Max(digits, minDigits);
		for (int d = digits - 1; d >= 0; d--)
		{
			uint32 nibble = (value >> (4 * d)) & 0xF;
			output.Append(nibble < 10 ? (char8)('0' + nibble) : (char8)('A' + nibble - 10));
		}
	}

	/// @brief Append `U+XXXX` (at least four uppercase hex digits).
	/// @param output The string to append to.
	/// @param cp The code point.
	public static void AppendCodePointName(String output, uint32 cp)
	{
		output.Append("U+");
		Append(output, cp, 4);
	}

	/// @brief Append a description of the character at `text[pos]` for an error message: `` `x` `` for
	/// a printable one, its code point name (`U+0009 (tab)`) for controls, whitespace and invisible
	/// ones, `the byte 0xXX` for a byte that starts no complete sequence.
	/// @param output The string to append to.
	/// @param text The text.
	/// @param pos Where the character starts.
	/// @param end The end of the available text.
	/// @param length Receives the character's byte length.
	public static void AppendCharDescription(String output, char8* text, int pos, int end, out int length)
	{
		uint8 b = (uint8)text[pos];
		int seqLen = Utf8.SequenceLength((char8)b);
		if (seqLen == 0 || pos + seqLen > end)
		{
			length = 1;
			output.AppendF("the byte 0x{:X2}", b);
			return;
		}
		uint32 cp = (uint32)Utf8.Decode(text, pos, out length);
		switch (cp)
		{
		case 0x00: output.Append("U+0000 (NUL)"); return;
		case 0x09: output.Append("U+0009 (tab)"); return;
		case 0x0A: output.Append("U+000A (line feed)"); return;
		case 0x0B: output.Append("U+000B (vertical tab)"); return;
		case 0x0C: output.Append("U+000C (form feed)"); return;
		case 0x0D: output.Append("U+000D (carriage return)"); return;
		case 0x20: output.Append("U+0020 (space)"); return;
		case 0xA0: output.Append("U+00A0 (no-break space)"); return;
		case 0xFEFF: output.Append("U+FEFF (byte order mark)"); return;
		}
		if (cp < 0x20 || cp == 0x7F || (cp >= 0x80 && cp < 0xA0) || (cp >= 0x2000 && cp <= 0x200F) ||
			(cp >= 0x2028 && cp <= 0x202F) || (cp >= 0x205F && cp <= 0x206F) || cp == 0x3000 || cp == 0x1680 || cp == 0x180E)
		{
			AppendCodePointName(output, cp);
			return;
		}
		output.Append('`');
		output.Append(text + pos, length);
		output.Append('`');
	}
}
