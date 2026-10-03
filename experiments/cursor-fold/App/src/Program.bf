using System;
using System.IO;
using FormatCore;
using internal FormatCore;

namespace App;

/// `<`, `&` and bytes below 0x20.
struct TextStops : IStopSet
{
	[Inline]
	public static uint64 Word(uint64 word) => Swar.BytesEqual(word, (uint8)'<') | Swar.BytesEqual(word, (uint8)'&') | Swar.BytesBelowSpace(word);

	[Inline]
	public static bool Byte(uint8 b) => b == (uint8)'<' || b == (uint8)'&' || b < 0x20;
}

/// UTF-8 checked by the reader, not up front (JSON's rule): the loop alone.
struct UncheckedText : ITextPolicy
{
	public static bool ValidatesUpFront
	{
		[Inline]
		get => false;
	}

	[Inline]
	public static bool IsPlainWord(uint64 word) => Swar.IsAscii(word);
	[Inline]
	public static bool AllowsAscii(uint8 b) => true;
	public static bool BansCodePoints
	{
		[Inline]
		get => false;
	}
	[Inline]
	public static bool AllowsCodePoint(uint32 cp) => true;
	public static void AppendBanned(String message, uint32 cp)
	{
	}
	[Inline]
	public static int NewlineLength(char8* text, int pos, int end) => Utf8.AsciiNewlineLength(text, pos, end);
	[Inline]
	public static uint64 MayHoldNewline(uint64 word) => Swar.BytesBelow0E(word);
	public static bool OnlyAsciiNewlines
	{
		[Inline]
		get => true;
	}
}

/// A reader core as the siblings write them: the window in fields, scans on locals, Grow through the
/// cursor's Fill, resuming where the scan stopped.
class ReaderCore<TCursor> where TCursor : IInputCursor
{
	public TCursor mCursor;
	char8* mData;
	int mBase;
	int mEnd;

	public this(TCursor cursor)
	{
		mCursor = cursor;
	}

	[Inline]
	bool Grow(int pos)
	{
		return mCursor.Fill(ref mData, ref mBase, ref mEnd, pos, pos, 1);
	}

	[NoInline]
	public int CountStops()
	{
		int pos = 0;
		switch (mCursor.Begin(ref mData, ref mBase, ref mEnd))
		{
		case .Ok(let start):
			pos = start;
		case .Err:
			return -1;
		}
		int stops = 0;
		while (true)
		{
			pos = Scan.Until<TextStops>(mData, pos, mEnd);
			if (pos >= mEnd)
			{
				if (!Grow(pos))
					break;
				continue;
			}
			stops++;
			pos++;
		}
		return stops;
	}
}

static class Program
{
	/// The same loop over a plain buffer (the control).
	[NoInline]
	static int CountDirect(char8* data, int length)
	{
		int pos = 0;
		int stops = 0;
		while (true)
		{
			pos = Scan.Until<TextStops>(data, pos, length);
			if (pos >= length)
				break;
			stops++;
			pos++;
		}
		return stops;
	}

	public static int Main(String[] args)
	{
		if (args.Count < 2)
		{
			Console.WriteLine("Usage: App <direct|memory|stream> <passes>");
			return 1;
		}
		int passes = int.Parse(args[1]).GetValueOrDefault();
		int length = 100 * 1024 * 1024;
		char8* data = new char8[length]*;
		defer delete data;
		for (int i < length)
			data[i] = (i % 61 == 60) ? '<' : (char8)('a' + i % 26);
		StringView input = .(data, length);
		InputSettings settings = default;
		int total = 0;
		let stream = scope MemoryStream();
		stream.TryWrite(Span<uint8>((uint8*)data, length));
		let state = scope InputState();
		for (int pass < passes)
		{
			stream.Position = 0;
			switch (args[0])
			{
			case "direct":
				total += CountDirect(data, length);
			case "memory":
				let core = scope:: ReaderCore<ByteCursor<UncheckedText>>(.(input, settings));
				total += core.CountStops();
			case "validated":
				let core = scope:: ReaderCore<ByteCursor<PlainUtf8Text>>(.(input, settings));
				total += core.CountStops();
			case "validate":
				total += Utf8.FindInvalid<PlainUtf8Text>(data, 0, length, scope String(), ?, ?);
			case "stream":
				let core = scope:: ReaderCore<BufferedStreamCursor<UncheckedText>>(.(stream, state, settings));
				total += core.CountStops();
			case "stream-validated":
				let core = scope:: ReaderCore<BufferedStreamCursor<PlainUtf8Text>>(.(stream, state, settings));
				total += core.CountStops();
			}
		}
		Console.WriteLine(total);
		return 0;
	}
}
