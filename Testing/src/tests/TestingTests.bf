using System;
using System.Collections;
using System.IO;

namespace FormatCore.Testing.Tests;

static class TestingTests
{
	[Test]
	public static void Measure_ConvergesOrCaps()
	{
		MeasureRule rule = .Default;
		rule.mWarmupSeconds = 0.01;
		rule.mMaxSeconds = 0.5;
		rule.mMaxSamples = 50;
		int runs = 0;
		let text = scope String();
		let steady = Bench.Measure(5, scope [&] () => {
			runs++;
			// Work the optimizer cannot remove (a sample of 0 ns would fail the median test)
			text.Clear();
			for (int i < 2000)
				text.Append((char8)('a' + i % 26));
			Test.Assert(text.Length == 2000);
		}, rule);
		Test.Assert(steady.mSamples >= 5 && steady.mSamples <= 50 && steady.mMedianNs > 0 && runs > steady.mSamples);
		// A rule nothing satisfies stops at the sample cap
		rule.mMajority = 2;
		let capped = Bench.Measure(1, scope () => { }, rule);
		Test.Assert(!capped.mConverged && capped.mSamples == 50);

		double[?] samples = .(100, 101, 99, 150, 98);
		Test.Assert(Bench.IsConverged(samples, 100, .Default));
		double[?] spread = .(100, 130, 70, 150, 98);
		Test.Assert(!Bench.IsConverged(spread, 100, .Default));

		text.Clear();
		Bench.FormatResult(text, .() { mMedianNs = 2.5e6, mSamples = 42, mConverged = true }, 1048576);
		Test.Assert(text == "2.500 ms/op 400.0 MB/s (n=42, converged)");
		text.Clear();
		Bench.FormatResult(text, .() { mMedianNs = 1e6, mSamples = 1000, mConverged = false }, 524288);
		Test.Assert(text == "1.000 ms/op 500.0 MB/s (n=1000, capped)");
	}

	[Test]
	public static void Inputs_ReadsFilesAndDirectoriesSorted()
	{
		let dir = scope String();
		Directory.GetCurrentDirectory(dir);
		dir.Append("/build/testing-inputs");
		let sub = scope $"{dir}/sub";
		Directory.CreateDirectory(sub).IgnoreError();
		defer
		{
			File.Delete(scope $"{sub}/a.txt").IgnoreError();
			File.Delete(scope $"{dir}/b.txt").IgnoreError();
			File.Delete(scope $"{dir}/c.txt").IgnoreError();
			Directory.Delete(sub).IgnoreError();
			Directory.Delete(dir).IgnoreError();
		}
		File.WriteAllText(scope $"{dir}/c.txt", "\u{FEFF}third").IgnoreError();
		File.WriteAllText(scope $"{dir}/b.txt", "first").IgnoreError();
		File.WriteAllText(scope $"{sub}/a.txt", "second").IgnoreError();

		let inputs = scope List<List<uint8>>();
		defer { ClearAndDeleteItems!(inputs); }
		Test.Assert(Inputs.ReadInputs(dir, inputs) case .Ok);
		Test.Assert(inputs.Count == 3);
		// b.txt, c.txt, sub/a.txt: sorted by path; the BOM kept
		Test.Assert(StringView((char8*)inputs[0].Ptr, inputs[0].Count) == "first");
		Test.Assert(StringView((char8*)inputs[1].Ptr, inputs[1].Count) == "\u{FEFF}third");
		Test.Assert(StringView((char8*)inputs[2].Ptr, inputs[2].Count) == "second");
		Test.Assert(Inputs.ReadInputs(scope $"{dir}/missing.txt", inputs) case .Err);
		Test.Assert(Inputs.ReadInputs(scope $"{sub}/a.txt", inputs) case .Ok && inputs.Count == 4);
	}

	[Test]
	public static void ChunkStream_ReadsInChunksAndFails()
	{
		StringView text = "0123456789abcdef";
		for (int chunk in ChunkStream.SweepSizes)
		{
			let stream = scope ChunkStream(text, chunk);
			let read = scope String();
			uint8[64] buffer = ?;
			while (true)
			{
				let count = stream.TryRead(.(&buffer, buffer.Count)).Value;
				if (count == 0)
					break;
				Test.Assert(count <= chunk);
				read.Append((char8*)&buffer, count);
			}
			Test.Assert(read == text);
		}
		Test.Assert(ChunkStream.SweepSizes.Length == 31 && ChunkStream.SweepSizes[30] == 31);
		let failing = scope ChunkStream(text, 4, 6);
		let bytes = scope List<uint8>();
		Test.Assert(Inputs.ReadAll(failing, bytes) case .Err && bytes.Count == 6);
	}

	[Test]
	public static void TextMutator_IsSeededAndLogs()
	{
		StringView[?] tokens = .("<", "<!--", "]]>", "\xFF");
		let a = scope TextMutator(42, tokens, "{}[],:\"");
		let b = scope TextMutator(42, tokens, "{}[],:\"");
		let textA = scope String("<doc><item a=\"1\">text</item></doc>");
		let textB = scope String(textA);
		for (int round < 200)
		{
			a.Mutate(textA);
			b.Mutate(textB);
			Test.Assert(textA == textB);
		}
		Test.Assert(a.mLog == b.mLog && !a.mLog.IsEmpty);

		// Every kind on an empty text does nothing or inserts
		for (int kind < 6)
		{
			let empty = scope String();
			a.Apply(empty, (MutationKind)kind);
			Test.Assert(empty.IsEmpty || (MutationKind)kind == .InsertToken || (MutationKind)kind == .InsertChar);
		}
		for (int i < 200)
		{
			let lead = (uint8)a.Character(.Utf8Lead);
			let continuation = (uint8)a.Character(.Utf8Continuation);
			let printable = (uint8)a.Character(.PrintableAscii);
			let interesting = a.Character(.Interesting);
			Test.Assert(lead >= 0xC0 && continuation >= 0x80 && continuation < 0xC0 && printable >= 0x20 && printable < 0x7F);
			Test.Assert(StringView("{}[],:\"").Contains(interesting));
		}
		let bytes = scope List<uint8>();
		StringView abc = "abc";
		bytes.AddRange(Span<uint8>((uint8*)abc.Ptr, 3));
		Test.Assert(a.Mutate(bytes, 1) == 1);
		let quoted = scope String();
		TextMutator.Quoted("a\"\xFF", quoted);
		Test.Assert(quoted == "\"a\\x22\\xFF\"");
	}

	[Test]
	public static void AgreementCheck_ReportsTheFirstDifference()
	{
		let check = scope AgreementCheck();
		check.Add("memory", new (input, outcome) => { outcome.Append(input); outcome.Append("\nend"); });
		check.Add("same", new (input, outcome) => { outcome.Append(input); outcome.Append("\nend"); });
		Test.Assert(check.Run("a\nb") && check.mMode.IsEmpty);
		check.Add("stream", new (input, outcome) => {
			outcome.Append(input);
			if (input.Contains('x'))
				outcome.Append("!");
			outcome.Append("\nend");
		});
		Test.Assert(check.Count == 3);
		Test.Assert(check.Run("a\nb"));
		Test.Assert(!check.Run("a\nbx"));
		Test.Assert(check.mMode == "stream" && check.mLine == 2 && check.mExpected == "bx" && check.mActual == "bx!");
		let report = scope String();
		check.Report(report);
		Test.Assert(report == "stream differs from memory at line 2:\n  memory: bx\n  stream: bx!\n");
	}
}
