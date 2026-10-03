using System;
using internal FormatCore;

namespace FormatCore;

/// What TryParsePlain accepts beyond `[-]digits[.digits][(e|E)[sign]digits]`.
internal enum PlainRules : uint8
{
	/// JSON's and TOML's integer part: no leading zeros (`01`), no `+`.
	None = 0,
	/// Leading zeros in the integer part (`007`, KDL).
	LeadingZeros = 1,
	/// A leading `+` (TOML, KDL).
	PlusSign = 2,
	/// Both.
	LeadingZerosAndPlus = 3
}

/// The result of TryParsePlain: an integer (no fraction, no exponent) or a correctly rounded double.
internal struct PlainNumber
{
	/// Whether the token had a fraction or an exponent.
	public bool mIsFloat;
	/// The integer's value (when not mIsFloat).
	public int64 mInteger;
	/// The double's value (when mIsFloat).
	public double mFloat;
}

/// What an integer token's value fits.
internal enum IntegerClass : uint8
{
	/// int64 (`-0` included, as 0).
	Int64,
	/// 2^63 to 2^64 − 1: uint64 only.
	UInt64,
	/// Beyond 64 bits.
	Big
}

/// The bits of IEEE 754 values.
internal static class FloatBits
{
	/// @brief Whether the sign bit of `value` is set (true for −0.0, which compares equal to 0).
	/// @param value The double.
	/// @return Whether it is.
	[Inline]
	public static bool IsNegative(double value)
	{
		var value;
		return ((*(uint64*)&value) >> 63) != 0;
	}

	/// @brief Whether the sign bit of `value` is set.
	/// @param value The float.
	/// @return Whether it is.
	[Inline]
	public static bool IsNegative(float value)
	{
		var value;
		return ((*(uint32*)&value) >> 31) != 0;
	}

	/// @brief The IEEE 754 bits of `value`.
	/// @param value The double.
	/// @return The bits.
	[Inline]
	public static uint64 ToBits(double value)
	{
		var value;
		return *(uint64*)&value;
	}

	/// @brief The double with IEEE 754 bits `bits`.
	/// @param bits The bits.
	/// @return The double.
	[Inline]
	public static double FromBits(uint64 bits)
	{
		var bits;
		return *(double*)&bits;
	}
}

/// Decimal text to numbers: Clinger's fast path (JsonBeef's, with exponents past 22 when the mantissa
/// stays exact), the one-pass plain parse of TomlBeef's and KdlBeef's readers, and the correctly rounded,
/// **culture-independent** general path (corlib's fast_float through `[Friend]` with `.` pinned: corlib's
/// public `double.Parse(text)` uses the current culture's decimal separator, initialized from the user's
/// locale). Grammar checks stay in the readers: these convert text a reader has validated, or report
/// false for anything they do not take.
internal static class DecimalParse
{
	/// Powers of ten that a double holds exactly (5^22 < 2^53).
	const double[23] cExactPowersOf10 = .(1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12,
		1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22);

	[Inline]
	static bool IsDigit(char8 c) => (uint8)c - (uint8)'0' <= 9;

	/// @brief Clinger's fast path: ±mantissa × 10^exponent when that is exact, so one IEEE multiply or
	/// divide rounds correctly: the mantissa at most 2^53 and the power an exact double (|exponent| ≤ 22),
	/// or a larger exponent whose excess multiplies into the mantissa exactly (`1e30`).
	/// @param mantissa The decimal digits' value.
	/// @param exponent The decimal exponent.
	/// @param negative The sign.
	/// @param value Receives the double.
	/// @return Whether the fast path applies (false: use ParseDouble).
	[Inline]
	public static bool TryClinger(uint64 mantissa, int exponent, bool negative, out double value)
	{
		value = 0;
		if (mantissa > (1UL << 53))
			return false;
		double result = (double)mantissa;
		if (exponent < 0)
		{
			if (exponent < -22)
				return false;
			result /= cExactPowersOf10[-exponent];
		}
		else if (exponent <= 22)
			result *= cExactPowersOf10[exponent];
		else
		{
			if (exponent > 22 + 15)
				return false;
			uint64 scaled = mantissa;
			for (int i < exponent - 22)
			{
				scaled *= 10;
				if (scaled > (1UL << 53))
					return false;
			}
			result = (double)scaled * 1e22;
		}
		value = negative ? -result : result;
		return true;
	}

	/// @brief One-pass parse of the common numbers, `[sign]digits[.digits][(e|E)[sign]digits]` without
	/// underscores (TomlBeef's TryParsePlainInteger and TryParsePlainFloat, KdlBeef's
	/// TryParsePlainNumber): an integer of 1-18 digits (it cannot overflow int64), or a decimal whose
	/// digits fit an exact mantissa (19 digits) and whose exponent Clinger's path takes. Anything else,
	/// valid or not, returns false: the reader's general path decides.
	/// @param token The token.
	/// @param rules Leading zeros and a `+` sign (a constant: the checks fold once inlined).
	/// @param number Receives the value.
	/// @return Whether the token was plain.
	[Inline]
	public static bool TryParsePlain(StringView token, PlainRules rules, out PlainNumber number)
	{
		number = default;
		char8* ptr = token.Ptr;
		int length = token.Length;
		if (length == 0)
			return false;
		int pos = 0;
		bool negative = false;
		if (ptr[0] == '-')
		{
			negative = true;
			pos = 1;
		}
		else if (ptr[0] == '+')
		{
			if (((uint8)rules & (uint8)PlainRules.PlusSign) == 0)
				return false;
			pos = 1;
		}
		uint64 mantissa = 0;
		int intStart = pos;
		while (pos < length && IsDigit(ptr[pos]) && pos - intStart < 19)
			mantissa = mantissa * 10 + ((uint8)ptr[pos++] - (uint8)'0');
		int intDigits = pos - intStart;
		if (intDigits == 0)
			return false;
		if (((uint8)rules & (uint8)PlainRules.LeadingZeros) == 0 && intDigits > 1 && ptr[intStart] == '0')
			return false;
		if (pos == length)
		{
			if (intDigits > 18)
				return false;
			number.mInteger = negative ? -(int64)mantissa : (int64)mantissa;
			return true;
		}
		int exponent = 0;
		if (ptr[pos] == '.')
		{
			pos++;
			int fracStart = pos;
			while (pos < length && IsDigit(ptr[pos]) && pos - fracStart + intDigits < 19)
				mantissa = mantissa * 10 + ((uint8)ptr[pos++] - (uint8)'0');
			if (pos == fracStart)
				return false;
			exponent = -(pos - fracStart);
		}
		if (pos < length && (ptr[pos] == 'e' || ptr[pos] == 'E'))
		{
			pos++;
			bool negativeExponent = false;
			if (pos < length && (ptr[pos] == '-' || ptr[pos] == '+'))
				negativeExponent = ptr[pos++] == '-';
			int expStart = pos;
			int expValue = 0;
			while (pos < length && IsDigit(ptr[pos]) && pos - expStart < 4)
				expValue = expValue * 10 + ((uint8)ptr[pos++] - (uint8)'0');
			if (pos == expStart)
				return false;
			exponent += negativeExponent ? -expValue : expValue;
		}
		// Too many digits, or anything else after the number
		if (pos != length)
			return false;
		number.mIsFloat = true;
		return TryClinger(mantissa, exponent, negative, out number.mFloat);
	}

	/// The fast path of ParseDouble (JsonBeef's TryParsePlainDouble): plain decimal text whose mantissa
	/// is exact; false otherwise (underscores, more digits, an exponent Clinger does not take).
	[Inline]
	static bool TryParseFast(StringView text, out double value)
	{
		value = 0;
		char8* ptr = text.Ptr;
		int length = text.Length;
		int pos = (length > 0 && (ptr[0] == '-' || ptr[0] == '+')) ? 1 : 0;
		uint64 mantissa = 0;
		int digits = 0;
		while (pos < length && IsDigit(ptr[pos]))
		{
			mantissa = mantissa * 10 + ((uint8)ptr[pos++] - (uint8)'0');
			digits++;
		}
		if (digits == 0 || digits > 19)
			return false;
		int exponent = 0;
		if (pos < length && ptr[pos] == '.')
		{
			pos++;
			int fracStart = pos;
			while (pos < length && IsDigit(ptr[pos]) && digits < 19)
			{
				mantissa = mantissa * 10 + ((uint8)ptr[pos++] - (uint8)'0');
				digits++;
			}
			if (pos < length && IsDigit(ptr[pos]))
				return false;
			exponent = -(pos - fracStart);
		}
		if (pos < length)
		{
			if (ptr[pos] != 'e' && ptr[pos] != 'E')
				return false;
			pos++;
			bool negativeExponent = false;
			if (pos < length && (ptr[pos] == '-' || ptr[pos] == '+'))
				negativeExponent = ptr[pos++] == '-';
			int expValue = 0;
			int expStart = pos;
			while (pos < length && IsDigit(ptr[pos]) && pos - expStart < 4)
				expValue = expValue * 10 + ((uint8)ptr[pos++] - (uint8)'0');
			if (pos == expStart || pos != length)
				return false;
			exponent += negativeExponent ? -expValue : expValue;
		}
		return TryClinger(mantissa, exponent, ptr[0] == '-', out value);
	}

	/// The text without its sign and underscores, on the stack (or the text itself without its sign).
	[Inline]
	static StringView Unsigned(StringView text, char8* buffer, int bufferLength, out bool negative)
	{
		negative = text.Length > 0 && text[0] == '-';
		StringView body = (text.Length > 0 && (text[0] == '-' || text[0] == '+')) ? text.Substring(1) : text;
		if (body.IndexOf('_') < 0)
			return body;
		int length = 0;
		for (let c in body)
		{
			if (c != '_' && length < bufferLength)
				buffer[length++] = c;
		}
		return .(buffer, length);
	}

	/// @brief The correctly rounded double of decimal text `[sign]digits[.digits][(e|E)[sign]digits]`
	/// (round to nearest, ties to even; an overflow gives ±∞ and an underflow ±0), whatever the current
	/// culture: `.` is the decimal point. Underscores (TOML and KDL digit separators) are skipped. The
	/// text must already be valid in its format; `inf` and `nan` are the format's to handle.
	/// @param text The number text.
	/// @param value Receives the double.
	/// @return False when corlib's parser does not take the text (not a decimal number).
	public static bool ParseDouble(StringView text, out double value)
	{
		if (TryParseFast(text, out value))
			return true;
		return ParseDoubleSlow(text, out value);
	}

	/// @brief The general path of ParseDouble alone (corlib's fast_float on the unsigned text), for
	/// testing the fast path against it.
	/// @param text The number text.
	/// @param value Receives the double.
	/// @return False when the text is not a decimal number.
	public static bool ParseDoubleSlow(StringView text, out double value)
	{
		value = 0;
		int capacity = Math.Max(text.Length, 1);
		char8* buffer = capacity <= 256 ? scope:: char8[256]* : scope:: char8[capacity]*;
		StringView body = Unsigned(text, buffer, capacity, let negative);
		if (body.IsEmpty)
			return false;
		double result = 0;
		if (!double.[Friend]Parse(body.Ptr, (int32)body.Length, '.', &result))
			return false;
		value = negative ? -result : result;
		return true;
	}

	/// @brief The correctly rounded float (binary32) of decimal text, parsed directly (through a double
	/// it would round twice: `7.038531e-26`), culture-independent, underscores skipped.
	/// @param text The number text.
	/// @param value Receives the float.
	/// @return False when the text is not a decimal number.
	public static bool ParseFloat32(StringView text, out float value)
	{
		value = 0;
		int capacity = Math.Max(text.Length, 1);
		char8* buffer = capacity <= 256 ? scope:: char8[256]* : scope:: char8[capacity]*;
		StringView body = Unsigned(text, buffer, capacity, let negative);
		if (body.IsEmpty)
			return false;
		float result = 0;
		if (!float.[Friend]Parse(body.Ptr, (int32)body.Length, '.', &result))
			return false;
		value = negative ? -result : result;
		return true;
	}

	/// The magnitude of `[sign]digits` (underscores skipped), if it fits uint64.
	static bool TryParseMagnitude(StringView text, out uint64 magnitude, out bool negative)
	{
		magnitude = 0;
		negative = text.Length > 0 && text[0] == '-';
		int pos = (text.Length > 0 && (text[0] == '-' || text[0] == '+')) ? 1 : 0;
		bool any = false;
		for (int i = pos; i < text.Length; i++)
		{
			char8 c = text[i];
			if (c == '_')
				continue;
			uint8 digit = (uint8)c - (uint8)'0';
			if (digit > 9)
				return false;
			if (magnitude > (uint64.MaxValue - digit) / 10)
				return false;
			magnitude = magnitude * 10 + digit;
			any = true;
		}
		return any;
	}

	/// @brief The int64 of a decimal integer `[sign]digits` (underscores skipped), if it fits.
	/// @param text The integer text.
	/// @param value Receives the value.
	/// @return Whether it is an integer that fits.
	public static bool TryParseInt64(StringView text, out int64 value)
	{
		value = 0;
		if (!TryParseMagnitude(text, let magnitude, let negative))
			return false;
		if (negative)
		{
			if (magnitude > (uint64)int64.MaxValue + 1)
				return false;
			value = magnitude == 0 ? 0 : -(int64)(magnitude - 1) - 1;
			return true;
		}
		if (magnitude > (uint64)int64.MaxValue)
			return false;
		value = (int64)magnitude;
		return true;
	}

	/// @brief The uint64 of a decimal integer `[sign]digits` (underscores skipped), if it fits (`-0`
	/// does; other negative values do not).
	/// @param text The integer text.
	/// @param value Receives the value.
	/// @return Whether it is an integer that fits.
	public static bool TryParseUInt64(StringView text, out uint64 value)
	{
		value = 0;
		if (!TryParseMagnitude(text, let magnitude, let negative))
			return false;
		if (negative && magnitude != 0)
			return false;
		value = magnitude;
		return true;
	}

	/// @brief What the value of a decimal integer `[sign]digits` fits (JsonBeef's Classify for integers).
	/// @param text A valid integer text.
	/// @return Int64, UInt64 or Big.
	public static IntegerClass ClassifyInteger(StringView text)
	{
		if (TryParseInt64(text, ?))
			return .Int64;
		if (TryParseUInt64(text, ?))
			return .UInt64;
		return .Big;
	}

	/// @brief The value of digits in radix 2, 8, 10 or 16 (no prefix, no sign; underscores skipped), if
	/// it fits uint64.
	/// @param digits The digits.
	/// @param radix 2, 8, 10 or 16.
	/// @param magnitude Receives the value.
	/// @return False for an empty text, a digit outside the radix, or an overflow.
	public static bool TryParseRadix(StringView digits, uint32 radix, out uint64 magnitude)
	{
		magnitude = 0;
		bool any = false;
		for (let c in digits)
		{
			if (c == '_')
				continue;
			uint32 digit = Hex.DigitValue(c);
			if (digit >= radix)
				return false;
			if (magnitude > (uint64.MaxValue - digit) / radix)
				return false;
			magnitude = magnitude * radix + digit;
			any = true;
		}
		return any;
	}
}
