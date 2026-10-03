using System;
using internal FormatCore;

namespace FormatCore;

/// An integer's radix.
internal enum IntegerBase : uint8
{
	Binary = 2,
	Octal = 8,
	Decimal = 10,
	Hex = 16
}

/// How an integer is written (TomlBeef's TomlIntegerFormat; KdlBeef's open item P5).
internal struct IntegerLayout
{
	public IntegerBase mBase;
	/// Uppercase hex digits (`0xDEAD`).
	public bool mUppercase;
	/// The `0x`, `0o` or `0b` prefix (never for decimal).
	public bool mPrefix;
	/// Digits padded with zeros to this many (0: none).
	public uint8 mMinDigits;
	/// An underscore every this many digits, from the right (0: none).
	public uint8 mGroupSize;

	/// @brief Plain decimal.
	public static IntegerLayout Decimal => .() { mBase = .Decimal };
}

/// Integer text in a base, with digit case, minimum digits and underscore grouping (TomlBeef's
/// WriteIntegerWithFormat and EmitGroupedDigits).
internal static class IntegerText
{
	/// @brief Append `value` as `layout` says: `-`, then the prefix, then the digits. (A format that
	/// writes negative values only in decimal, like TOML, chooses the decimal layout for them.)
	/// @param output The string to append to.
	/// @param value The value.
	/// @param layout The layout.
	public static void Append(String output, int64 value, IntegerLayout layout)
	{
		if (value < 0)
		{
			output.Append('-');
			AppendUnsigned(output, (uint64)(-(value + 1)) + 1, layout);
			return;
		}
		AppendUnsigned(output, (uint64)value, layout);
	}

	/// @brief Append `value` as `layout` says (no sign).
	/// @param output The string to append to.
	/// @param value The value.
	/// @param layout The layout.
	public static void AppendUnsigned(String output, uint64 value, IntegerLayout layout)
	{
		uint32 radix = (uint32)layout.mBase;
		if (radix != 2 && radix != 8 && radix != 16)
			radix = 10;
		if (layout.mPrefix && radix != 10)
			output.Append(radix == 16 ? "0x" : radix == 8 ? "0o" : "0b");
		// Digits least significant first, then reversed
		char8[64] digits = ?;
		int count = 0;
		char8 letter = layout.mUppercase ? 'A' : 'a';
		var value;
		repeat
		{
			uint32 digit = (uint32)(value % radix);
			digits[count++] = digit < 10 ? (char8)('0' + digit) : (char8)(letter + digit - 10);
			value /= radix;
		}
		while (value != 0);
		while (count < Math.Min((int)layout.mMinDigits, 64))
			digits[count++] = '0';
		for (int i < count)
		{
			if (layout.mGroupSize > 0 && i > 0 && (count - i) % layout.mGroupSize == 0)
				output.Append('_');
			output.Append(digits[count - 1 - i]);
		}
	}

	/// @brief Append `digits` with an underscore every `groupSize` digits, counted from the right
	/// (`1_000_000`) or from the left (a fraction: `445_991_2`).
	/// @param output The string to append to.
	/// @param digits The digits.
	/// @param groupSize The group size (0: no underscores).
	/// @param fromLeft Count groups from the left.
	public static void AppendGrouped(String output, StringView digits, int groupSize, bool fromLeft = false)
	{
		if (groupSize <= 0 || digits.Length <= groupSize)
		{
			output.Append(digits);
			return;
		}
		int first = fromLeft ? groupSize : digits.Length % groupSize;
		if (first == 0)
			first = groupSize;
		output.Append(digits.Substring(0, first));
		int pos = first;
		while (pos < digits.Length)
		{
			output.Append('_');
			int chunk = Math.Min(groupSize, digits.Length - pos);
			output.Append(digits.Substring(pos, chunk));
			pos += chunk;
		}
	}
}
