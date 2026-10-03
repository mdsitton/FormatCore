using System;
using System.Collections;
using internal FormatCore;

namespace FormatCore;

/// Integers of any size as decimal text, and the exact decimal value of a double (KdlBeef's
/// AppendIntegerLexeme, JsonBeef's AppendHexAsDecimal and its patch's exact comparison).
internal static class BigDecimal
{
	/// @brief Append the digits of an integer in radix 2, 8, 10 or 16 (no prefix, no sign; underscores
	/// skipped) as decimal text, with `-` when `negative` and the value is not zero. Radix 10 is copied
	/// in linear time (leading zeros dropped); the others convert through base-2^32 limbs.
	/// @param output The string to append to.
	/// @param digits The digits (valid in the radix).
	/// @param radix 2, 8, 10 or 16.
	/// @param negative The sign.
	public static void AppendRadixAsDecimal(String output, StringView digits, uint32 radix, bool negative)
	{
		int n = digits.Length;
		int i = 0;
		if (radix == 10)
		{
			while (i < n && (digits[i] == '0' || digits[i] == '_'))
				i++;
			if (i == n)
			{
				output.Append('0');
				return;
			}
			if (negative)
				output.Append('-');
			for (; i < n; i++)
			{
				if (digits[i] != '_')
					output.Append(digits[i]);
			}
			return;
		}
		// Little-endian base-2^32 limbs: multiply-add each digit, then divide by 10^9 repeatedly
		let limbs = scope List<uint32>();
		for (; i < n; i++)
		{
			if (digits[i] == '_')
				continue;
			uint64 carry = Hex.DigitValue(digits[i]);
			for (int k < limbs.Count)
			{
				uint64 product = (uint64)limbs[k] * radix + carry;
				limbs[k] = (uint32)product;
				carry = product >> 32;
			}
			if (carry != 0)
				limbs.Add((uint32)carry);
		}
		while (!limbs.IsEmpty && limbs.Back == 0)
			limbs.PopBack();
		if (limbs.IsEmpty)
		{
			output.Append('0');
			return;
		}
		let chunks = scope List<uint32>();
		while (!limbs.IsEmpty)
		{
			uint64 remainder = 0;
			for (int k = limbs.Count - 1; k >= 0; k--)
			{
				uint64 current = (remainder << 32) | limbs[k];
				limbs[k] = (uint32)(current / 1000000000);
				remainder = current % 1000000000;
			}
			chunks.Add((uint32)remainder);
			while (!limbs.IsEmpty && limbs.Back == 0)
				limbs.PopBack();
		}
		if (negative)
			output.Append('-');
		chunks.Back.ToString(output);
		for (int k = chunks.Count - 2; k >= 0; k--)
			AppendNineDigits(output, chunks[k]);
	}

	static void AppendNineDigits(String output, uint32 chunk)
	{
		char8[9] text = ?;
		var chunk;
		for (int d = 8; d >= 0; d--)
		{
			text[d] = (char8)('0' + chunk % 10);
			chunk /= 10;
		}
		output.Append(&text, 9);
	}

	/// limbs × factor (factor below 2^32), base-10^9 limbs, in place.
	static void Multiply(List<uint32> limbs, uint64 factor)
	{
		uint64 carry = 0;
		for (int i < limbs.Count)
		{
			uint64 product = (uint64)limbs[i] * factor + carry;
			limbs[i] = (uint32)(product % 1000000000);
			carry = product / 1000000000;
		}
		while (carry != 0)
		{
			limbs.Add((uint32)(carry % 1000000000));
			carry /= 1000000000;
		}
	}

	/// @brief Append the exact value of a finite double as decimal integer digits and, when the binary
	/// exponent is negative, `e<power>`: the value is digits × 10^power (0.1 is
	/// `1000000000000000055511151231257827021181583404541015625e-55`). JsonBeef's exact number
	/// comparison decomposes it.
	/// @param output The string to append to.
	/// @param value The double (finite).
	public static void AppendExact(String output, double value)
	{
		uint64 bits = FloatBits.ToBits(value);
		uint64 mantissa = bits & (((uint64)1 << 52) - 1);
		int biased = (int)((bits >> 52) & 0x7FF);
		int power = -1074;
		if (biased != 0)
		{
			mantissa |= (uint64)1 << 52;
			power = biased - 1075;
		}
		// mantissa × 2^power: by 2s, or by 5s and a decimal exponent of `power`
		let limbs = scope List<uint32>();
		limbs.Add((uint32)(mantissa % 1000000000));
		limbs.Add((uint32)((mantissa / 1000000000) % 1000000000));
		limbs.Add((uint32)(mantissa / 1000000000000000000));
		int twos = Math.Max(power, 0);
		int fives = Math.Max(-power, 0);
		while (twos > 0)
		{
			int step = Math.Min(twos, 28);
			Multiply(limbs, (uint64)1 << step);
			twos -= step;
		}
		while (fives > 0)
		{
			int step = Math.Min(fives, 12);
			uint64 factor = 1;
			for (int i < step)
				factor *= 5;
			Multiply(limbs, factor);
			fives -= step;
		}
		while (limbs.Count > 1 && limbs.Back == 0)
			limbs.PopBack();
		if (bits >> 63 != 0)
			output.Append('-');
		int start = output.Length;
		limbs.Back.ToString(output);
		for (int i = limbs.Count - 2; i >= 0; i--)
			AppendNineDigits(output, limbs[i]);
		if (power < 0 && !(limbs.Count == 1 && limbs[0] == 0))
		{
			// Trailing zeros go into the power: the shortest exact form
			while (power < 0 && output.Length - start > 1 && output[output.Length - 1] == '0')
			{
				output.RemoveFromEnd(1);
				power++;
			}
			if (power < 0)
				output.AppendF("e{}", power);
		}
	}
}
