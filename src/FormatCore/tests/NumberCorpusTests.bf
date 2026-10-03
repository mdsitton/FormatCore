using System;
using System.Collections;
using System.IO;
using internal FormatCore;

namespace FormatCore.Tests;

/// The number corpora (JsonBeef's -fxx and -es6 drivers, run against FormatCore directly): only when
/// FORMATCORE_NUMBER_CORPUS names a directory holding `parse-number-fxx/*.txt` and
/// `es6-numbers/es6testfile-*.txt` (tools/test-number-corpus.sh sets it; JsonBeef's
/// tests/fetch-suites.sh fetches them). Without it the test does nothing.
static class NumberCorpusTests
{
	static uint64 ParseHex(StringView text)
	{
		uint64 value = 0;
		for (let c in text)
			value = (value << 4) | Hex.DigitValue(c);
		return value;
	}

	[Test]
	public static void Corpus_FxxAndEs6()
	{
		let root = scope String();
		if (Environment.GetEnvironmentVariable("FORMATCORE_NUMBER_CORPUS", root) case .Err || root.IsEmpty)
			return;
		int lines = 0;
		int unparsed = 0;
		int mismatches = 0;
		let fxx = scope String();
		fxx.AppendF("{}/parse-number-fxx", root);
		for (let entry in Directory.EnumerateFiles(fxx, "*.txt"))
		{
			let path = entry.GetFilePath(.. scope .());
			let text = scope String();
			Test.Assert(File.ReadAllText(path, text) case .Ok, path);
			for (let line in text.Split('\n'))
			{
				// `f16 f32 f64 text`
				if (line.Length < 32 || line[4] != ' ' || line[13] != ' ' || line[30] != ' ')
					continue;
				lines++;
				StringView number = line.Substring(31);
				if (number.EndsWith('\r'))
					number.RemoveFromEnd(1);
				uint64 f64 = ParseHex(line.Substring(14, 16));
				uint64 f32 = ParseHex(line.Substring(5, 8));
				if (!DecimalParse.ParseDouble(number, let value))
				{
					unparsed++;
					continue;
				}
				var single = 0.0f;
				bool parsedSingle = DecimalParse.ParseFloat32(number, out single);
				if (FloatBits.ToBits(value) != f64 || !parsedSingle || *(uint32*)&single != (uint32)f32)
				{
					if (mismatches++ < 10)
						Console.WriteLine($"fxx mismatch: {number}");
				}
			}
		}
		Console.WriteLine($"fxx: {lines} lines, {unparsed} not decimal numbers, {mismatches} mismatches");
		Test.Assert(lines > 1000000 && mismatches == 0);

		// es6: `bits,text`
		let es6 = scope String();
		es6.AppendF("{}/es6-numbers", root);
		int es6Lines = 0;
		int es6Mismatches = 0;
		let written = scope String();
		for (let entry in Directory.EnumerateFiles(es6, "es6testfile-*.txt"))
		{
			let path = entry.GetFilePath(.. scope .());
			let text = scope String();
			Test.Assert(File.ReadAllText(path, text) case .Ok, path);
			for (let line in text.Split('\n'))
			{
				int comma = line.IndexOf(',');
				if (comma < 0)
					continue;
				es6Lines++;
				StringView expected = line.Substring(comma + 1);
				if (expected.EndsWith('\r'))
					expected.RemoveFromEnd(1);
				double value = FloatBits.FromBits(ParseHex(line.Substring(0, comma)));
				written.Clear();
				ShortestDouble.Append(written, value, .EcmaScript);
				bool backOk = DecimalParse.ParseDouble(written, let back) && (FloatBits.ToBits(back) == FloatBits.ToBits(value) || value == 0);
				if (written != expected || !backOk)
				{
					if (es6Mismatches++ < 10)
						Console.WriteLine($"es6 mismatch: {written}, expected {expected}");
				}
			}
		}
		Console.WriteLine($"es6: {es6Lines} lines, {es6Mismatches} mismatches");
		Test.Assert(es6Lines >= 100000 && es6Mismatches == 0);
	}
}
