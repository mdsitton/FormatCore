using System;
using System.Collections;
using System.Globalization;
using internal FormatCore;

namespace FormatCore.Tests;

static class NumbersTests
{
	static uint64 Bits(StringView text)
	{
		Test.Assert(DecimalParse.ParseDouble(text, let value));
		return FloatBits.ToBits(value);
	}

	[Test]
	public static void Clinger_MatchesTheGeneralPath()
	{
		let random = scope Random(2024);
		let text = scope String();
		int fast = 0;
		for (int round < 20000)
		{
			uint64 mantissa = (uint64)random.NextI64() & ((1UL << (1 + random.Next(53))) - 1);
			int exponent = random.Next(-30, 45);
			bool negative = random.Next(2) == 0;
			text.Clear();
			if (negative)
				text.Append('-');
			text.AppendF("{}e{}", mantissa, exponent);
			Test.Assert(DecimalParse.ParseDoubleSlow(text, let slow));
			if (DecimalParse.TryClinger(mantissa, exponent, negative, let clinger))
			{
				fast++;
				Test.Assert(FloatBits.ToBits(clinger) == FloatBits.ToBits(slow), text);
			}
			// The whole entry point, fast path or not
			Test.Assert(DecimalParse.ParseDouble(text, let parsed) && FloatBits.ToBits(parsed) == FloatBits.ToBits(slow), text);
		}
		Test.Assert(fast > 10000);
		// Plain decimals with fractions, through TryParsePlain
		for (int round < 20000)
		{
			text.Clear();
			text.AppendF("{}.{}", random.Next(0, 1000000), random.Next(0, 100000000));
			if (random.Next(3) == 0)
				text.AppendF("e{}", random.Next(-20, 20));
			Test.Assert(DecimalParse.ParseDoubleSlow(text, let slow));
			if (DecimalParse.TryParsePlain(text, .LeadingZeros, let plain))
			{
				Test.Assert(plain.mIsFloat);
				Test.Assert(FloatBits.ToBits(plain.mFloat) == FloatBits.ToBits(slow), text);
			}
		}
	}

	[Test]
	public static void ParseDouble_KnownValues()
	{
		Test.Assert(Bits("0.1") == 0x3FB999999999999AUL);
		Test.Assert(Bits("1e23") == 0x44B52D02C7E14AF6UL);
		Test.Assert(Bits("9007199254740993.000000000000000000001") == 0x4340000000000001UL);
		Test.Assert(Bits("123456789012345678901234567890") == 0x45F8EE90FF6C373EUL);
		Test.Assert(Bits("-0.0") == 0x8000000000000000UL);
		Test.Assert(Bits("+1.5") == Bits("1.5"));
		// Digit separators
		Test.Assert(Bits("1_000.000_5") == Bits("1000.0005"));
		Test.Assert(Bits("6.626_070_15e-34") == Bits("6.62607015e-34"));
		Test.Assert(Bits("1_2_3_4_5_6_7_8_9_0_1_2_3_4_5_6_7_8_9_0.5") == Bits("12345678901234567890.5"));
		// Out of range is not a failure
		Test.Assert(DecimalParse.ParseDouble("1e400", let huge) && huge == double.PositiveInfinity);
		Test.Assert(DecimalParse.ParseDouble("-1e-400", let tiny) && tiny == 0 && FloatBits.IsNegative(tiny));
		Test.Assert(!DecimalParse.ParseDouble("", ?));
		Test.Assert(!DecimalParse.ParseDouble("abc", ?));
		// binary32 directly, not through a double
		Test.Assert(DecimalParse.ParseFloat32("7.038531e-26", var single));
		Test.Assert(*(uint32*)&single == 0x15AE43FD);
		Test.Assert(DecimalParse.ParseFloat32("-0.1", out single) && single == -0.1f);
	}

	[Test]
	public static void ParseDouble_IgnoresTheCurrentCulture()
	{
		// Bug 2 (TomlBeef's slow-path float parse, TomlParser.Values.bf:898): corlib's double.Parse(text)
		// uses the current culture's decimal separator. With a culture whose separator is `,` it misreads
		// `1.5`; DecimalParse does not.
		let culture = scope CultureInfo("de-DE");
		let format = new NumberFormatInfo();
		format.NumberDecimalSeparator = ",";
		culture.mNumInfo = format;
		let saved = CultureInfo.CurrentCulture;
		CultureInfo.CurrentCulture = culture;
		defer { CultureInfo.CurrentCulture = saved; }

		Test.Assert(NumberFormatInfo.CurrentInfo.NumberDecimalSeparator == ",");
		let corlib = double.Parse("1.5");
		Test.Assert(!(corlib case .Ok(1.5)));
		Test.Assert(DecimalParse.ParseDouble("1.5", let value) && value == 1.5);
		// The general path too (more digits than the fast path takes)
		Test.Assert(DecimalParse.ParseDouble("1.50000000000000000000001", let slow) && slow == 1.5);
		Test.Assert(DecimalParse.ParseFloat32("2.25", let single) && single == 2.25f);
		// And the output side: the shortest digits never use the culture
		let text = scope String();
		ShortestDouble.Append(text, 1.5, .TomlCanonical);
		Test.Assert(text == "1.5");
	}

	[Test]
	public static void TryParsePlain_Rules()
	{
		Test.Assert(DecimalParse.TryParsePlain("12345", .None, let integer) && !integer.mIsFloat && integer.mInteger == 12345);
		Test.Assert(DecimalParse.TryParsePlain("-42", .None, let negative) && negative.mInteger == -42);
		Test.Assert(DecimalParse.TryParsePlain("-0", .None, let zero) && zero.mInteger == 0);
		// 18 digits always fit; 19 go to the general path
		Test.Assert(DecimalParse.TryParsePlain("999999999999999999", .None, let big) && big.mInteger == 999999999999999999);
		Test.Assert(!DecimalParse.TryParsePlain("9223372036854775807", .None, ?));
		// Leading zeros and plus signs by rule
		Test.Assert(!DecimalParse.TryParsePlain("007", .None, ?));
		Test.Assert(DecimalParse.TryParsePlain("007", .LeadingZeros, let padded) && padded.mInteger == 7);
		Test.Assert(!DecimalParse.TryParsePlain("+7", .None, ?));
		Test.Assert(DecimalParse.TryParsePlain("+7", .PlusSign, let plus) && plus.mInteger == 7);
		Test.Assert(DecimalParse.TryParsePlain("00.5", .LeadingZerosAndPlus, let half) && half.mIsFloat && half.mFloat == 0.5);
		Test.Assert(!DecimalParse.TryParsePlain("00.5", .PlusSign, ?));
		Test.Assert(DecimalParse.TryParsePlain("0.5", .None, ?));
		// Floats
		Test.Assert(DecimalParse.TryParsePlain("1.5e3", .None, let thousand) && thousand.mFloat == 1500);
		Test.Assert(DecimalParse.TryParsePlain("1E-2", .None, let hundredth) && hundredth.mFloat == 0.01);
		Test.Assert(DecimalParse.TryParsePlain("-2.5", .None, let minus) && minus.mFloat == -2.5);
		// Not plain: the general path decides
		StringView[?] others = .("", "-", "1.", ".5", "1e", "1e+", "1_000", "1.0_1", "inf", "1x", "1.5.2", "1e5e5", "0x1F",
			"1.2345678901234567890", "1e99999");
		for (let other in others)
			Test.Assert(!DecimalParse.TryParsePlain(other, .LeadingZerosAndPlus, ?), scope String(other));
	}

	[Test]
	public static void Integers_ParseAndClassify()
	{
		Test.Assert(DecimalParse.TryParseInt64("9223372036854775807", let max) && max == int64.MaxValue);
		Test.Assert(DecimalParse.TryParseInt64("-9223372036854775808", let min) && min == int64.MinValue);
		Test.Assert(!DecimalParse.TryParseInt64("9223372036854775808", ?));
		Test.Assert(!DecimalParse.TryParseInt64("-9223372036854775809", ?));
		Test.Assert(DecimalParse.TryParseInt64("1_000_000", let million) && million == 1000000);
		Test.Assert(DecimalParse.TryParseUInt64("18446744073709551615", let umax) && umax == uint64.MaxValue);
		Test.Assert(!DecimalParse.TryParseUInt64("18446744073709551616", ?));
		Test.Assert(DecimalParse.TryParseUInt64("-0", let negativeZero) && negativeZero == 0);
		Test.Assert(!DecimalParse.TryParseUInt64("-1", ?));
		Test.Assert(!DecimalParse.TryParseInt64("", ?) && !DecimalParse.TryParseInt64("1.5", ?));
		Test.Assert(DecimalParse.ClassifyInteger("-9223372036854775808") == .Int64);
		Test.Assert(DecimalParse.ClassifyInteger("9223372036854775808") == .UInt64);
		Test.Assert(DecimalParse.ClassifyInteger("18446744073709551616") == .Big);
		Test.Assert(DecimalParse.ClassifyInteger("-9223372036854775809") == .Big);
		Test.Assert(DecimalParse.TryParseRadix("DEAD_beef", 16, let hex) && hex == 0xDEADBEEF);
		Test.Assert(DecimalParse.TryParseRadix("777", 8, let octal) && octal == 511);
		Test.Assert(DecimalParse.TryParseRadix("1010", 2, let binary) && binary == 10);
		Test.Assert(!DecimalParse.TryParseRadix("12", 2, ?) && !DecimalParse.TryParseRadix("", 16, ?));
		Test.Assert(DecimalParse.TryParseRadix("FFFFFFFFFFFFFFFF", 16, let all) && all == uint64.MaxValue);
		Test.Assert(!DecimalParse.TryParseRadix("10000000000000000", 16, ?));
	}

	static void CheckLayout(double value, FloatLayout layout, StringView expected)
	{
		let text = scope String();
		Test.Assert(ShortestDouble.Append(text, value, layout));
		Test.Assert(text == expected, scope $"`{text}`, expected `{expected}`");
	}

	[Test]
	public static void Layouts_JsonPlainAndEcmaScript()
	{
		// JsonBeef's Numbers_PlainLayout
		(double value, StringView text)[?] plain = .((1.0, "1.0"), (100.0, "100.0"), (0.0, "0.0"), (-0.0, "-0.0"),
			(1e21, "1e21"), (1e20, "100000000000000000000.0"), (1.5e-7, "1.5e-7"), (5e-324, "5e-324"),
			(1.7976931348623157e308, "1.7976931348623157e308"), (-1.2345, "-1.2345"), (0.000001, "0.000001"),
			(2.225073858507201e-308, "2.225073858507201e-308"));
		for (let sample in plain)
			CheckLayout(sample.value, .JsonPlain, sample.text);
		// JsonBeef's E157, E158, E068, E162 (RFC 8785 samples)
		(double value, StringView text)[?] ecma = .((1e21, "1e+21"), (1e20, "100000000000000000000"), (1e-7, "1e-7"),
			(0.000001, "0.000001"), (5e-324, "5e-324"), (0.1 + 0.2, "0.30000000000000004"), (-0.0, "0"), (1e23, "1e+23"));
		for (let sample in ecma)
			CheckLayout(sample.value, .EcmaScript, sample.text);
		(uint64 bits, StringView text)[?] samples = .(
			(0x0000000000000000UL, "0"), (0x8000000000000000UL, "0"), (0x7FEFFFFFFFFFFFFFUL, "1.7976931348623157e+308"),
			(0x4340000000000000UL, "9007199254740992"), (0x4430000000000000UL, "295147905179352830000"),
			(0x44B52D02C7E14AF5UL, "9.999999999999997e+22"), (0x444B1AE4D6E2EF4FUL, "999999999999999900000"),
			(0x3EB0C6F7A0B5ED8CUL, "9.999999999999997e-7"), (0x41B3DE4355555554UL, "333333333.33333325"),
			(0xBECBF647612F3696UL, "-0.0000033333333333333333"), (0x43143FF3C1CB0959UL, "1424953923781206.2"));
		for (let sample in samples)
			CheckLayout(FloatBits.FromBits(sample.bits), .EcmaScript, sample.text);
		// Non-finite values are the format's
		let text = scope String();
		Test.Assert(!ShortestDouble.Append(text, double.NaN, .JsonPlain) && !ShortestDouble.Append(text, double.PositiveInfinity, .JsonPlain));
		Test.Assert(text.IsEmpty);
	}

	[Test]
	public static void Layouts_KdlAndToml()
	{
		// KdlBeef's canonical doubles (KdlCanonical.AppendDouble: corlib's text, `.0`, `E+`)
		CheckLayout(1.0, .KdlCanonical, "1.0");
		CheckLayout(1e10, .KdlCanonical, "10000000000.0");
		CheckLayout(1e16, .KdlCanonical, "1.0E+16");
		CheckLayout(1.5e-3, .KdlCanonical, "0.0015");
		CheckLayout(1.5e-7, .KdlCanonical, "1.5E-07");
		CheckLayout(-0.0, .KdlCanonical, "-0.0");
		CheckLayout(1.2345678901234568e+20, .KdlCanonical, "1.2345678901234568E+20");
		// TomlBeef's canonical floats (`R` text, `.0` when neither point nor exponent)
		CheckLayout(1.0, .TomlCanonical, "1.0");
		CheckLayout(3.14, .TomlCanonical, "3.14");
		CheckLayout(1e16, .TomlCanonical, "1e+16");
		CheckLayout(1e-5, .TomlCanonical, "1e-05");
		CheckLayout(-0.0, .TomlCanonical, "-0.0");
		CheckLayout(0.0, .TomlCanonical, "0.0");
		// TomlBeef's scientific notation (TomlRegressionTests B1, TomlPreserveStyleWriterTests)
		CheckLayout(3.141592653589793, FloatLayout.Scientific(false, false, 0), "3.141592653589793e0");
		CheckLayout(1e5, FloatLayout.Scientific(true, true, 2), "1E+05");
		CheckLayout(-2.5e-3, FloatLayout.Scientific(false, false, 0), "-2.5e-3");
		CheckLayout(2000, FloatLayout.Scientific(true, true, 3), "2E+003");
		CheckLayout(2500, FloatLayout.Scientific(true, true, 2), "2.5E+03");
		CheckLayout(2000, FloatLayout.Scientific(false, false, 0), "2e3");
		CheckLayout(1.2345678901234567e10, FloatLayout.Scientific(false, false, 0), "1.2345678901234568e10");
		CheckLayout(5e-324, FloatLayout.Scientific(false, false, 0), "5e-324");
		CheckLayout(0.0, FloatLayout.Scientific(false, false, 0), "0e0");
		// Every layout reads back as the same double
		let random = scope Random(11);
		FloatLayout[?] layouts = .(.JsonPlain, .EcmaScript, .KdlCanonical, .TomlCanonical, FloatLayout.Scientific(true, true, 3));
		let text = scope String();
		for (int round < 5000)
		{
			double value = FloatBits.FromBits((uint64)random.NextI64());
			if (!value.IsFinite)
				continue;
			for (let layout in layouts)
			{
				text.Clear();
				ShortestDouble.Append(text, value, layout);
				Test.Assert(DecimalParse.ParseDouble(text, let back) && FloatBits.ToBits(back) == FloatBits.ToBits(value) ||
					(value == 0 && layout.mUnsignedZero), text);
			}
		}
	}

	[Test]
	public static void Layouts_Float32()
	{
		let text = scope String();
		ShortestDouble.Append(text, 0.1f, .JsonPlain);
		Test.Assert(text == "0.1");
		text.Clear();
		ShortestDouble.Append(text, 1e30f, .EcmaScript);
		Test.Assert(text == "1e+30");
		text.Clear();
		ShortestDouble.Append(text, -0.0f, .JsonPlain);
		Test.Assert(text == "-0.0");
		char8[32] digits = ?;
		int count = ShortestDouble.Digits(1.5f, &digits, var point);
		Test.Assert(count == 2 && digits[0] == '1' && digits[1] == '5' && point == 1);
		count = ShortestDouble.Digits(0.00125, &digits, out point);
		Test.Assert(count == 3 && point == -2);
		Test.Assert(ShortestDouble.Digits(0.0, &digits, out point) == 0);
	}

	static void CheckInteger(int64 value, IntegerLayout layout, StringView expected)
	{
		let text = scope String();
		IntegerText.Append(text, value, layout);
		Test.Assert(text == expected, scope $"`{text}`, expected `{expected}`");
	}

	[Test]
	public static void IntegerText_Layouts()
	{
		CheckInteger(0, .Decimal, "0");
		CheckInteger(-1234567, .Decimal, "-1234567");
		CheckInteger(int64.MinValue, .Decimal, "-9223372036854775808");
		CheckInteger(1000000, .() { mBase = .Decimal, mGroupSize = 3 }, "1_000_000");
		CheckInteger(100000, .() { mBase = .Decimal, mGroupSize = 3 }, "100_000");
		CheckInteger(0xDEADBEEF, .() { mBase = .Hex, mPrefix = true, mUppercase = true }, "0xDEADBEEF");
		CheckInteger(0xff, .() { mBase = .Hex, mPrefix = true, mMinDigits = 4 }, "0x00ff");
		CheckInteger(0xDEADBEEF, .() { mBase = .Hex, mPrefix = true, mGroupSize = 4 }, "0xdead_beef");
		CheckInteger(493, .() { mBase = .Octal, mPrefix = true }, "0o755");
		CheckInteger(10, .() { mBase = .Binary, mPrefix = true, mMinDigits = 8, mGroupSize = 4 }, "0b0000_1010");
		CheckInteger(0, .() { mBase = .Binary, mPrefix = true }, "0b0");
		let text = scope String();
		IntegerText.AppendUnsigned(text, uint64.MaxValue, .() { mBase = .Hex });
		Test.Assert(text == "ffffffffffffffff");
		text.Clear();
		IntegerText.AppendGrouped(text, "4459912", 3, true);
		text.Append(' ');
		IntegerText.AppendGrouped(text, "224617", 3);
		text.Append(' ');
		IntegerText.AppendGrouped(text, "12", 3);
		Test.Assert(text == "445_991_2 224_617 12");
	}

	/// Naive reference: the digits in `radix` as decimal, by repeated multiply-add on decimal text.
	static void NaiveRadixToDecimal(StringView digits, uint32 radix, String output)
	{
		let value = scope List<uint8>();
		value.Add(0);
		for (let c in digits)
		{
			if (c == '_')
				continue;
			uint32 carry = Hex.DigitValue(c);
			for (int i < value.Count)
			{
				uint32 v = value[i] * radix + carry;
				value[i] = (uint8)(v % 10);
				carry = v / 10;
			}
			while (carry > 0)
			{
				value.Add((uint8)(carry % 10));
				carry /= 10;
			}
		}
		int top = value.Count - 1;
		while (top > 0 && value[top] == 0)
			top--;
		for (int i = top; i >= 0; i--)
			output.Append((char8)('0' + value[i]));
	}

	[Test]
	public static void BigDecimal_RadixConversion()
	{
		let random = scope Random(3);
		let digits = scope String();
		let expected = scope String();
		let actual = scope String();
		uint32[?] radixes = .(2, 8, 10, 16);
		for (int round < 400)
		{
			uint32 radix = radixes[round % 4];
			digits.Clear();
			int length = 1 + random.Next(80);
			for (int i < length)
			{
				uint32 digit = (uint32)random.Next((int32)radix);
				digits.Append(digit < 10 ? (char8)('0' + digit) : (char8)('A' + digit - 10));
				if (random.Next(7) == 0)
					digits.Append('_');
			}
			expected.Clear();
			actual.Clear();
			NaiveRadixToDecimal(digits, radix, expected);
			BigDecimal.AppendRadixAsDecimal(actual, digits, radix, false);
			Test.Assert(actual == expected, digits);
		}
		actual.Clear();
		BigDecimal.AppendRadixAsDecimal(actual, "0_0", 16, true);
		actual.Append(' ');
		BigDecimal.AppendRadixAsDecimal(actual, "ff", 16, true);
		actual.Append(' ');
		BigDecimal.AppendRadixAsDecimal(actual, "00_123", 10, true);
		actual.Append(' ');
		BigDecimal.AppendRadixAsDecimal(actual, "1_0000_0000_0000_0000", 16, false);
		Test.Assert(actual == "0 -255 -123 18446744073709551616");
	}

	[Test]
	public static void BigDecimal_ExactDoubles()
	{
		let text = scope String();
		BigDecimal.AppendExact(text, 0.1);
		Test.Assert(text == "1000000000000000055511151231257827021181583404541015625e-55");
		text.Clear();
		BigDecimal.AppendExact(text, 1e23);
		Test.Assert(text == "99999999999999991611392");
		text.Clear();
		BigDecimal.AppendExact(text, -2.5);
		Test.Assert(text == "-25e-1");
		text.Clear();
		BigDecimal.AppendExact(text, 0.0);
		Test.Assert(text == "0");
		text.Clear();
		BigDecimal.AppendExact(text, 5e-324);
		Test.Assert(text.StartsWith("4940656458412465441765687928682213723650598026143247644255856825006755072702087518652998363616359923797965646954457177309266567103559397963987747960107818781263007131903114045278458171678489821036887186360569987307230500063874091535649843873124733972731696151400317153853980741262385655911710266585566867681870395603106249319452715914924553293054565444011274801297099995419319894090804165633245247571478690147267801593552386115501348035264934720193790268107107491703332226844753335720832431936092382893458368060106011506169809753078342277318329247904982524730776375927247874656084778203734469699533647017972677717585125660551199131504891101451037862738167250955837389733598993664809941164205702637090279242767544565229087538682506419718265533447265625e-1074"));
	}
}
