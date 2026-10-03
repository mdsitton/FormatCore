using System;
using internal FormatCore;

namespace FormatCore;

/// Where a float's digits go.
internal enum FloatNotation : uint8
{
	/// corlib's round-trip text as it lays it out (fixed for decimal exponents from −4 to 15 for a
	/// double, else `d.ddde±XX`), restyled: KdlBeef's and TomlBeef's canonical forms are built on it.
	Native,
	/// ECMAScript's `Number::toString` ranges: fixed for decimal exponents from −6 to 20, else `d.ddde±X`
	/// (JsonBeef's Plain and EcmaScript, RFC 8785).
	EcmaScript,
	/// Always `d[.ddd]e±X` (TomlBeef's scientific notation).
	Scientific
}

/// When `.0` is added so that the text stays a float.
internal enum FractionRule : uint8
{
	/// Never.
	None,
	/// When the text has neither a point nor an exponent (`1.0`, `1e21`).
	Integral,
	/// Whenever the mantissa has no point, exponent or not (`1.0`, `1.0E+21`).
	Mantissa
}

/// How a float is written (ShortestDouble.Append): notation, `.0`, the exponent's marker, sign and
/// width, and negative zero.
internal struct FloatLayout
{
	public FloatNotation mNotation;
	public FractionRule mFraction;
	/// `E` instead of `e`.
	public bool mUpperExponent;
	/// `e+5` instead of `e5` (a negative exponent always has its `-`).
	public bool mExponentPlus;
	/// The exponent's digits padded with zeros (or its leading zeros trimmed) to this width; 0: Native
	/// keeps corlib's digits (`e-05`), the other notations write the fewest.
	public uint8 mExponentDigits;
	/// −0 written as `0` (ECMAScript).
	public bool mUnsignedZero;

	/// @brief JsonBeef's Plain: `1.0`, `100.0`, `1e21`, `1.5e-7`, `-0.0`.
	public static FloatLayout JsonPlain => .() { mNotation = .EcmaScript, mFraction = .Integral };

	/// @brief ECMAScript's `Number::toString` (RFC 8785): `1`, `1e+21`, `1.5e-7`, `0` for −0.
	public static FloatLayout EcmaScript => .() { mNotation = .EcmaScript, mExponentPlus = true, mUnsignedZero = true };

	/// @brief KdlBeef's canonical double: `1.0`, `1.0E+21`, `1.5E-07`, `-0.0`.
	public static FloatLayout KdlCanonical => .() { mNotation = .Native, mFraction = .Mantissa, mUpperExponent = true, mExponentPlus = true };

	/// @brief TomlBeef's canonical float (corlib's "R" text, `.0` when it has neither point nor exponent):
	/// `1.0`, `1e+16`, `1.5e-07`, `-0.0`.
	public static FloatLayout TomlCanonical => .() { mNotation = .Native, mFraction = .Integral, mExponentPlus = true };

	/// @brief TomlBeef's scientific notation with a captured exponent style (`1.5e3`, `2.5E+03`).
	/// @param upper `E`.
	/// @param plus An explicit `+`.
	/// @param digits The exponent's width (0: the fewest).
	/// @return The layout.
	public static FloatLayout Scientific(bool upper, bool plus, int digits)
	{
		return .() { mNotation = .Scientific, mUpperExponent = upper, mExponentPlus = plus, mExponentDigits = (uint8)digits };
	}
}

/// Shortest round-trip digits (corlib's zmij writer, `[Friend]ToString_RoundTripFast`) laid out in a
/// format's notation (JsonBeef's AppendDouble/AppendLayout, KdlBeef's AppendDouble, TomlBeef's
/// canonical float and AppendRoundTripScientific/ReformatExponent).
internal static class ShortestDouble
{
	/// @brief The shortest round-trip significant digits of a finite `value`, without leading or
	/// trailing zeros, with the decimal point position: the value is ±0.d1d2… × 10^point.
	/// @param value The double (finite).
	/// @param digits Receives the digits (room for 32).
	/// @param point Receives the point position.
	/// @return The digit count, 0 for zero.
	public static int Digits(double value, char8* digits, out int point)
	{
		char8[64] text = ?;
		int length = double.[Friend]ToString_RoundTripFast(value, &text);
		return DigitsOf(&text, length, digits, out point);
	}

	/// @brief The shortest digits that read back as the float (binary32) `value`.
	/// @param value The float (finite).
	/// @param digits Receives the digits (room for 32).
	/// @param point Receives the point position.
	/// @return The digit count, 0 for zero.
	public static int Digits(float value, char8* digits, out int point)
	{
		char8[64] text = ?;
		int length = float.[Friend]ToString_RoundTripFast(value, &text);
		return DigitsOf(&text, length, digits, out point);
	}

	/// The significant digits and point position of corlib's round-trip text (`[-]ddd[.ddd][e±dd]`).
	static int DigitsOf(char8* text, int length, char8* digits, out int point)
	{
		int pos = 0;
		if (text[0] == '-')
			pos++;
		int count = 0;
		int intDigits = -1;
		int leadingZeros = 0;
		while (pos < length && text[pos] != 'e' && text[pos] != 'E')
		{
			char8 c = text[pos++];
			if (c == '.')
			{
				intDigits = count + leadingZeros;
				continue;
			}
			if (c == '0' && count == 0)
			{
				leadingZeros++;
				continue;
			}
			digits[count++] = c;
		}
		if (intDigits < 0)
			intDigits = count + leadingZeros;
		int exponent = 0;
		if (pos < length)
		{
			pos++;
			bool negative = false;
			if (text[pos] == '+' || text[pos] == '-')
				negative = text[pos++] == '-';
			while (pos < length)
				exponent = exponent * 10 + (text[pos++] - '0');
			if (negative)
				exponent = -exponent;
		}
		while (count > 0 && digits[count - 1] == '0')
			count--;
		point = intDigits + exponent - leadingZeros;
		return count;
	}

	/// @brief Append the shortest text that reads back as `value`, laid out as `layout` says.
	/// Non-finite values are the format's (`inf`, `NaN`, `Infinity`): nothing is written for them.
	/// @param output The string to append to.
	/// @param value The double.
	/// @param layout The layout.
	/// @return False (and nothing written) for a NaN or an infinity.
	[Inline]
	public static bool Append(String output, double value, FloatLayout layout)
	{
		if (!value.IsFinite)
			return false;
		if (layout.mNotation != .Native)
		{
			// The digits out of line (Digits), the layout inlined into the caller
			char8[32] digits = ?;
			int count = Digits(value, &digits, let point);
			AppendDigits(output, &digits, count, point, FloatBits.IsNegative(value), layout);
			return true;
		}
		char8[64] text = ?;
		int length = double.[Friend]ToString_RoundTripFast(value, &text);
		AppendText(output, &text, length, FloatBits.IsNegative(value), layout);
		return true;
	}

	/// @brief Append the shortest text that reads back as the float (binary32) `value` (`0.1`, not the
	/// double's `0.10000000149011612`).
	/// @param output The string to append to.
	/// @param value The float.
	/// @param layout The layout.
	/// @return False (and nothing written) for a NaN or an infinity.
	public static bool Append(String output, float value, FloatLayout layout)
	{
		if (!value.IsFinite)
			return false;
		char8[64] text = ?;
		int length = float.[Friend]ToString_RoundTripFast(value, &text);
		AppendText(output, &text, length, FloatBits.IsNegative(value), layout);
		return true;
	}

	static void AppendText(String output, char8* text, int length, bool negative, FloatLayout layout)
	{
		// Native restyles corlib's text as it is: no digits to take apart (the canonical writers' path)
		if (layout.mNotation == .Native && !layout.mUnsignedZero)
		{
			AppendNative(output, text, length, layout);
			return;
		}
		char8[32] digits = ?;
		int count = DigitsOf(text, length, &digits, let point);
		if (layout.mNotation == .Native)
		{
			// AppendNative writes the text's sign itself: here the sign is decided above (an unsigned zero)
			if (negative && !(count == 0 && layout.mUnsignedZero))
				output.Append('-');
			AppendNative(output, text + (negative ? 1 : 0), length - (negative ? 1 : 0), layout);
			return;
		}
		AppendDigits(output, &digits, count, point, negative, layout);
	}

	/// The EcmaScript and Scientific layouts of `count` digits with the point at `point`. Inlined, so a
	/// caller with a constant layout gets its own copy with the layout's tests folded (JsonBeef's writer
	/// measured 2.5% without).
	[Inline]
	static void AppendDigits(String output, char8* digits, int count, int point, bool negative, FloatLayout layout)
	{
		if (negative && !(count == 0 && layout.mUnsignedZero))
			output.Append('-');
		switch (layout.mNotation)
		{
		case .Native:
			Runtime.FatalError("ShortestDouble: the Native layout needs corlib's text");
		case .EcmaScript:
			if (count == 0)
			{
				output.Append('0');
				if (layout.mFraction != .None)
					output.Append(".0");
				return;
			}
			int n = point;
			int k = count;
			if (k <= n && n <= 21)
			{
				output.Append(digits, k);
				// (No call for no zeros: most values have none)
				if (n > k)
					output.Append('0', n - k);
				if (layout.mFraction != .None)
					output.Append(".0");
			}
			else if (0 < n && n <= 21)
			{
				output.Append(digits, n);
				output.Append('.');
				output.Append(digits + n, k - n);
			}
			else if (-6 < n && n <= 0)
			{
				output.Append("0.");
				if (n < 0)
					output.Append('0', -n);
				output.Append(digits, k);
			}
			else
				AppendScientific(output, digits, k, n - 1, layout);
		case .Scientific:
			if (count == 0)
			{
				char8 zero = '0';
				AppendScientific(output, &zero, 1, 0, layout);
				return;
			}
			AppendScientific(output, digits, count, point - 1, layout);
		}
	}

	/// `d[.ddd]` and the exponent.
	static void AppendScientific(String output, char8* digits, int count, int exponent, FloatLayout layout)
	{
		output.Append(digits[0]);
		if (count > 1)
		{
			output.Append('.');
			output.Append(digits + 1, count - 1);
		}
		else if (layout.mFraction == .Mantissa)
			output.Append(".0");
		char8[16] exponentDigits = ?;
		int value = Math.Abs(exponent);
		int width = 0;
		repeat
		{
			exponentDigits[width++] = (char8)('0' + value % 10);
			value /= 10;
		}
		while (value != 0);
		AppendExponent(output, exponent < 0, &exponentDigits, width, true, layout);
	}

	/// The marker, the sign and the digits (given most significant last when `reversed`).
	static void AppendExponent(String output, bool negative, char8* exponentDigits, int count, bool reversed, FloatLayout layout)
	{
		output.Append(layout.mUpperExponent ? 'E' : 'e');
		if (negative)
			output.Append('-');
		else if (layout.mExponentPlus)
			output.Append('+');
		// Leading zeros: the digits as given, then trimmed or padded to the width
		int first = 0;
		if (layout.mExponentDigits > 0)
		{
			while (count - first > layout.mExponentDigits && Digit(exponentDigits, count, first, reversed) == '0')
				first++;
			output.Append('0', layout.mExponentDigits - (count - first));
		}
		for (int i = first; i < count; i++)
			output.Append(Digit(exponentDigits, count, i, reversed));
	}

	[Inline]
	static char8 Digit(char8* digits, int count, int i, bool reversed) => reversed ? digits[count - 1 - i] : digits[i];

	/// corlib's text restyled (its sign included): its mantissa (with `.0` per the rule) and its
	/// exponent's digits, composed on the stack and appended in one call.
	static void AppendNative(String output, char8* text, int length, FloatLayout layout)
	{
		// Most text has no exponent: one scan, then the text and perhaps `.0` as they are
		int exponentAt = length;
		bool hasDot = false;
		for (int i < length)
		{
			char8 c = text[i];
			if (c == '.')
				hasDot = true;
			else if (c == 'e' || c == 'E')
			{
				exponentAt = i;
				break;
			}
		}
		if (exponentAt == length)
		{
			output.Append(text, length);
			if (!hasDot && layout.mFraction != .None)
				output.Append(".0");
			return;
		}
		char8[80] buffer = ?;
		int n = 0;
		int pos = 0;
		bool hasPoint = false;
		while (pos < length && text[pos] != 'e' && text[pos] != 'E')
		{
			char8 c = text[pos++];
			hasPoint |= c == '.';
			buffer[n++] = c;
		}
		bool hasExponent = pos < length;
		if (!hasPoint && (layout.mFraction == .Mantissa || (layout.mFraction == .Integral && !hasExponent)))
		{
			buffer[n++] = '.';
			buffer[n++] = '0';
		}
		if (hasExponent)
		{
			pos++;
			buffer[n++] = layout.mUpperExponent ? 'E' : 'e';
			bool negativeExponent = false;
			if (pos < length && (text[pos] == '+' || text[pos] == '-'))
				negativeExponent = text[pos++] == '-';
			if (negativeExponent)
				buffer[n++] = '-';
			else if (layout.mExponentPlus)
				buffer[n++] = '+';
			// The digits as given, trimmed or padded to the width
			int first = pos;
			if (layout.mExponentDigits > 0)
			{
				while (length - first > layout.mExponentDigits && text[first] == '0')
					first++;
				for (int pad = length - first; pad < layout.mExponentDigits; pad++)
					buffer[n++] = '0';
			}
			for (int i = first; i < length; i++)
				buffer[n++] = text[i];
		}
		output.Append(&buffer, n);
	}
}
