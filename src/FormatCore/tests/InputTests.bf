using System;
using System.Collections;
using internal FormatCore;

namespace FormatCore.Tests;

static class InputTests
{
	/// Text with every newline kind, multi-byte characters and KDL's extra newlines.
	static void MakeText(Random random, int length, bool kdlNewlines, String output)
	{
		StringView[?] pieces = .("a", "bc", " ", "\n", "\r", "\r\n", "\u{E9}", "\u{20AC}", "\u{1F600}", "\t", "xyzxyzxyz");
		StringView[?] kdl = .("\u{85}", "\u{2028}", "\u{2029}", "\x0B", "\x0C");
		while (output.Length < length)
		{
			if (kdlNewlines && random.Next(4) == 0)
				output.Append(kdl[random.Next(kdl.Count)]);
			else
				output.Append(pieces[random.Next(pieces.Count)]);
		}
	}

	static void CheckCounter<TText>(StringView text) where TText : ITextPolicy
	{
		// One counter moved forward through every boundary, and a fresh one per offset
		var counter = LineCounter<TText>(0);
		for (int offset <= text.Length)
		{
			if (offset < text.Length && ((uint8)text[offset] & 0xC0) == 0x80)
				continue;
			Utf8.LineAndColumn<TText>(text, offset, let line, let column);
			counter.Locate(text.Ptr, offset, text.Length, var countedLine, var countedColumn);
			Test.Assert(countedLine == line && countedColumn == column);
			var fresh = LineCounter<TText>(0);
			fresh.Locate(text.Ptr, offset, text.Length, out countedLine, out countedColumn);
			Test.Assert(countedLine == line && countedColumn == column);
		}
	}

	[Test]
	public static void LineCounter_MatchesTheNaiveLocator()
	{
		let random = scope Random(1234);
		let text = scope String();
		for (int round < 60)
		{
			text.Clear();
			MakeText(random, 1 + random.Next(120), false, text);
			CheckCounter<PlainUtf8Text>(text);
			CheckCounter<KdlLikeText>(text);
			text.Clear();
			MakeText(random, 1 + random.Next(120), true, text);
			CheckCounter<KdlLikeText>(text);
		}
		// An offset on the LF of a CRLF is on the line the CRLF ends, after its CR
		Utf8.LineAndColumn<PlainUtf8Text>("ab\r\ncd", 3, var line, var column);
		Test.Assert(line == 1 && column == 4);
		var counter = LineCounter<PlainUtf8Text>(0);
		counter.Locate("ab\r\ncd".Ptr, 3, 6, out line, out column);
		Test.Assert(line == 1 && column == 4);
		counter.Locate("ab\r\ncd".Ptr, 4, 6, out line, out column);
		Test.Assert(line == 2 && column == 1);
		// A BOM takes no column
		Utf8.LineAndColumn<PlainUtf8Text>("\u{FEFF}ab", 4, out line, out column);
		Test.Assert(line == 1 && column == 2);
	}

	[Test]
	public static void LineIndex_MatchesTheNaiveLocator()
	{
		let random = scope Random(99);
		let text = scope String();
		let index = scope LineIndex<KdlLikeText>();
		for (int round < 40)
		{
			text.Clear();
			if (round % 3 == 0)
				text.Append("\u{FEFF}");
			MakeText(random, 1 + random.Next(150), round % 2 == 0, text);
			index.Clear();
			for (int offset <= text.Length)
			{
				Utf8.LineAndColumn<KdlLikeText>(text, offset, let line, let column);
				index.Locate(text.Ptr, text.Length, offset, let indexedLine, let indexedColumn);
				if (offset < text.Length && ((uint8)text[offset] & 0xC0) == 0x80)
					continue;
				Test.Assert(indexedLine == line && indexedColumn == column);
			}
		}
	}

	/// Reads every byte through the cursor one at a time, locating every `locateEvery` bytes; the
	/// output gets the bytes, `failed` and `error` the input's error.
	static void ReadAll<TCursor, TText>(ref TCursor cursor, StringView input, String output, int locateEvery, out bool failed, out InputError error)
		where TCursor : IInputCursor where TText : ITextPolicy
	{
		char8* data = null;
		int windowStart = 0;
		int end = 0;
		failed = false;
		error = default;
		int pos = 0;
		switch (cursor.Begin(ref data, ref windowStart, ref end))
		{
		case .Ok(let start):
			pos = start;
		case .Err(let beginError):
			failed = true;
			error = beginError;
			return;
		}
		int count = 0;
		while (true)
		{
			if (pos >= end && !cursor.Fill(ref data, ref windowStart, ref end, pos, pos, 1))
				break;
			Test.Assert(pos >= windowStart && pos < end);
			if (locateEvery > 0 && count++ % locateEvery == 0 && ((uint8)data[pos] & 0xC0) != 0x80)
			{
				Test.Assert(cursor.Locate(pos, let line, let column));
				Utf8.LineAndColumn<TText>(input, pos, let expectedLine, let expectedColumn);
				Test.Assert(line == expectedLine && column == expectedColumn);
			}
			output.Append(data[pos]);
			pos++;
		}
		if (cursor.TryGetInputError(out error))
			failed = true;
	}

	static void CheckSameAsMemory<TText>(StringView input, InputSettings settings) where TText : ITextPolicy
	{
		let memoryOutput = scope String();
		var memory = ByteCursor<TText>(input, settings);
		ReadAll<ByteCursor<TText>, TText>(ref memory, input, memoryOutput, 3, let memoryFailed, var memoryError);
		InputErrorKind memoryKind = memoryError.mKind;
		int memoryOffset = (int)memoryError.mOffset;
		int memoryLine = memoryError.mLine;
		int memoryColumn = memoryError.mColumn;
		let memoryMessage = scope String(memoryError.mMessage);
		let state = scope InputState();
		for (int chunk = 1; chunk <= 31; chunk += (chunk < 8 ? 1 : 7))
		{
			for (int bufferSize in int[?](16, 17, 64))
			{
				var streamSettings = settings;
				streamSettings.mStreamBufferBytes = bufferSize;
				let stream = scope ChunkStream(input, chunk);
				var cursor = BufferedStreamCursor<TText>(stream, state, streamSettings);
				let output = scope String();
				ReadAll<BufferedStreamCursor<TText>, TText>(ref cursor, input, output, 5, let failed, let error);
				Test.Assert(failed == memoryFailed);
				if (failed)
				{
					Test.Assert(error.mKind == memoryKind && error.mOffset == memoryOffset);
					Test.Assert(error.mLine == memoryLine && error.mColumn == memoryColumn);
					Test.Assert(error.mMessage == memoryMessage);
					// The bytes before the error were delivered, unless it was in the first buffer (Begin's error)
					int start = Utf8.StartsWithBom(input.Ptr, input.Length) ? 3 : 0;
					Test.Assert(output.IsEmpty || output == input.Substring(start, Math.Max(memoryOffset - start, 0)));
					if (memoryOffset >= bufferSize + 8)
						Test.Assert(!output.IsEmpty);
				}
				else
					Test.Assert(output == memoryOutput);
			}
		}
	}

	[Test]
	public static void Cursors_StreamsDeliverWhatMemoryDoes()
	{
		let random = scope Random(7);
		let text = scope String();
		InputSettings settings = default;
		for (int round < 25)
		{
			text.Clear();
			if (round % 4 == 1)
				text.Append("\u{FEFF}");
			MakeText(random, 1 + random.Next(200), round % 2 == 0, text);
			CheckSameAsMemory<PlainUtf8Text>(text, settings);
			CheckSameAsMemory<KdlLikeText>(text, settings);
			CheckSameAsMemory<JsonLikeText>(text, settings);
			// The same with an error late in the text
			text.Append("\u{200E}ok");
			CheckSameAsMemory<KdlLikeText>(text, settings);
			text.Append((char8)0xFF);
			CheckSameAsMemory<PlainUtf8Text>(text, settings);
		}
	}

	[Test]
	public static void Cursors_InputStart()
	{
		InputSettings settings = default;
		settings.mFormatName = "TOML";
		let memoryCases = scope List<StringView>();
		memoryCases.Add("\xFF\xFEa\0");
		memoryCases.Add("a\0b\0");
		memoryCases.Add("\0\0\0a");
		for (let input in memoryCases)
		{
			var cursor = ByteCursor<PlainUtf8Text>(input, settings);
			char8* data = null;
			int windowStart = 0;
			int end = 0;
			let result = cursor.Begin(ref data, ref windowStart, ref end);
			Test.Assert(result case .Err(let error) && error.mKind == .UnsupportedEncoding);
		}
		var utf16 = ByteCursor<PlainUtf8Text>("\xFF\xFEa\0", settings);
		char8* data = null;
		int windowStart = 0;
		int end = 0;
		if (utf16.Begin(ref data, ref windowStart, ref end) case .Err(let error))
			Test.Assert(error.mMessage == "The input is UTF-16LE (TOML must be UTF-8): transcode it first");
		// A rule cited verbatim
		var cited = settings;
		cited.mUtf8Rule = "JSON must be UTF-8, RFC 8259 §8.1";
		var json = ByteCursor<PlainUtf8Text>("\xFF\xFEa\0", cited);
		if (json.Begin(ref data, ref windowStart, ref end) case .Err(let citedError))
			Test.Assert(citedError.mMessage == "The input is UTF-16LE (JSON must be UTF-8, RFC 8259 §8.1): transcode it first");
		else
			Test.Assert(false);

		// A BOM is skipped, or rejected
		var bom = ByteCursor<PlainUtf8Text>("\u{FEFF}x", settings);
		Test.Assert(bom.Begin(ref data, ref windowStart, ref end) case .Ok(3));
		settings.mBom = .Reject;
		var rejected = ByteCursor<PlainUtf8Text>("\u{FEFF}x", settings);
		Test.Assert(rejected.Begin(ref data, ref windowStart, ref end) case .Err(let bomError) && bomError.mKind == .ByteOrderMark);
		// A BOM split across reads
		settings.mBom = .Skip;
		let state = scope InputState();
		let stream = scope ChunkStream("\u{FEFF}xyz", 1);
		var streamed = BufferedStreamCursor<PlainUtf8Text>(stream, state, settings);
		Test.Assert(streamed.Begin(ref data, ref windowStart, ref end) case .Ok(3));
		Test.Assert(end == 6 && data[3] == 'x');
	}

	[Test]
	public static void Cursors_Limits()
	{
		InputSettings settings = default;
		settings.mMaxInputBytes = 10;
		char8* data = null;
		int windowStart = 0;
		int end = 0;
		var memory = ByteCursor<PlainUtf8Text>("0123456789A", settings);
		Test.Assert(memory.Begin(ref data, ref windowStart, ref end) case .Err(let tooLarge) && tooLarge.mKind == .ResourceLimitExceeded);
		Test.Assert(tooLarge.mMessage == "The input (11 bytes) exceeds MaxInputBytes (10)");

		// Over the limit in the first buffer: Begin fails, as from memory
		let state = scope InputState();
		String output = scope .();
		StringView large = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
		let stream = scope ChunkStream(large, 4);
		var streamed = BufferedStreamCursor<PlainUtf8Text>(stream, state, settings);
		ReadAll<BufferedStreamCursor<PlainUtf8Text>, PlainUtf8Text>(ref streamed, large, output, 0, var failed, var error);
		Test.Assert(failed && error.mKind == .ResourceLimitExceeded && error.mOffset == 10 && output.IsEmpty);
		// Later: the bytes up to the limit are delivered
		settings.mMaxInputBytes = 30;
		settings.mStreamBufferBytes = 16;
		let later = scope ChunkStream(large, 4);
		streamed = BufferedStreamCursor<PlainUtf8Text>(later, state, settings);
		ReadAll<BufferedStreamCursor<PlainUtf8Text>, PlainUtf8Text>(ref streamed, large, output, 0, out failed, out error);
		Test.Assert(failed && error.mKind == .ResourceLimitExceeded && error.mOffset == 30 && output == large.Substring(0, 30));
		Test.Assert(error.mMessage == "The input exceeds MaxInputBytes (30)");

		// An I/O error after 20 bytes (after the first buffer)
		settings = default;
		settings.mStreamBufferBytes = 16;
		output.Clear();
		let failing = scope ChunkStream(large, 4, 20);
		var broken = BufferedStreamCursor<PlainUtf8Text>(failing, state, settings);
		ReadAll<BufferedStreamCursor<PlainUtf8Text>, PlainUtf8Text>(ref broken, large, output, 0, var ioFailed, var ioError);
		Test.Assert(ioFailed && ioError.mKind == .IoError && ioError.mOffset == 20 && output == large.Substring(0, 20));
	}

	/// Reads space-separated tokens, keeping each token's start in the window.
	static bool ReadTokens(ref BufferedStreamCursor<PlainUtf8Text> cursor, List<String> tokens, out InputError error)
	{
		char8* data = null;
		int windowStart = 0;
		int end = 0;
		error = default;
		int pos = 0;
		switch (cursor.Begin(ref data, ref windowStart, ref end))
		{
		case .Ok(let start):
			pos = start;
		case .Err(let beginError):
			error = beginError;
			return false;
		}
		while (true)
		{
			// Skip spaces (nothing kept)
			while ((pos < end || cursor.Fill(ref data, ref windowStart, ref end, pos, pos, 1)) && data[pos] == ' ')
				pos++;
			if (pos >= end)
				break;
			int tokenStart = pos;
			while ((pos < end || cursor.Fill(ref data, ref windowStart, ref end, tokenStart, pos, 1)) && data[pos] != ' ')
				pos++;
			if (cursor.HasInputError && pos >= end)
				break;
			tokens.Add(new String(StringView(data + tokenStart, pos - tokenStart)));
		}
		return !cursor.TryGetInputError(out error);
	}

	[Test]
	public static void Cursors_MaxTokenBytesIsAHardLimitOnTheConstruct()
	{
		let state = scope InputState();
		let tokens = scope List<String>();
		defer { ClearAndDeleteItems!(tokens); }
		InputSettings settings = default;
		// The limit covers the construct and the lookahead the reader asks for (here the byte after a
		// token, to see that it ends)
		settings.mMaxTokenBytes = 9;
		StringView input = "aaaa bbbbbbbb cccccccccccc d";
		for (int chunk in int[?](1, 3, 64))
		{
			ClearAndDeleteItems!(tokens);
			let stream = scope ChunkStream(input, chunk);
			var cursor = BufferedStreamCursor<PlainUtf8Text>(stream, state, settings);
			Test.Assert(!ReadTokens(ref cursor, tokens, let error));
			// "bbbbbbbb" and its terminator (9 bytes) fit; the 12-byte token does not
			Test.Assert(tokens.Count == 2 && tokens[1] == "bbbbbbbb");
			Test.Assert(error.mKind == .ResourceLimitExceeded && error.mOffset == 14 + 9);
			Test.Assert(error.mMessage == "A token is longer than MaxTokenBytes (9)");
		}
		// A limit below the buffer's minimum, and a token that ends the input at the limit exactly
		settings.mMaxTokenBytes = 3;
		ClearAndDeleteItems!(tokens);
		let small = scope ChunkStream("ab abc", 2);
		var cursor = BufferedStreamCursor<PlainUtf8Text>(small, state, settings);
		Test.Assert(ReadTokens(ref cursor, tokens, ?));
		Test.Assert(tokens.Count == 2 && tokens[1] == "abc");
		// Long tokens grow the buffer without a limit
		settings = default;
		settings.mStreamBufferBytes = 16;
		ClearAndDeleteItems!(tokens);
		let longText = scope String();
		for (int i < 100)
			longText.Append("0123456789");
		longText.Append(" end");
		let longStream = scope ChunkStream(longText, 7);
		var growing = BufferedStreamCursor<PlainUtf8Text>(longStream, state, settings);
		Test.Assert(ReadTokens(ref growing, tokens, ?));
		Test.Assert(tokens.Count == 2 && tokens[0].Length == 1000 && tokens[1] == "end");
	}

	[Test]
	public static void Window_Rebase()
	{
		char8[8] oldBuffer = "abcdefgh";
		char8[8] newBuffer = "ABCDEFGH";
		StringView inside = .(&oldBuffer[2], 3);
		StringView outside = "zz";
		char8* oldData = &oldBuffer[0];
		Window.Rebase(ref inside, oldData, oldData + 8, oldData, &newBuffer[0]);
		Window.Rebase(ref outside, oldData, oldData + 8, oldData, &newBuffer[0]);
		Test.Assert(inside == "CDE" && outside == "zz");
	}
}
