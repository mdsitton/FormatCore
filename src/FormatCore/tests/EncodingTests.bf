using System;
using System.Collections;
using internal FormatCore;

namespace FormatCore.Tests;

/// A detector with a declaration, for testing the hook: `@name\n` at the start names the encoding (a
/// table's, or anything else for the converter); without it, Bom.Detect. A declaration without its
/// newline yet is incomplete.
internal struct AtDetector : IEncodingDetector
{
	public static int PrefixBytes
	{
		[Inline]
		get => 4;
	}

	public static Result<EncodingDetection, InputError> Detect(StringView prefix, String declared, String scratch)
	{
		declared.Clear();
		if (prefix.IsEmpty || prefix[0] != '@')
			return Bom.Detect(prefix);
		EncodingDetection detection = .();
		int newline = prefix.IndexOf('\n');
		if (newline < 0)
		{
			detection.mIncomplete = true;
			return detection;
		}
		let name = prefix.Substring(1, newline - 1);
		declared.Set(name);
		detection.mNameOffset = 1;
		detection.mNameLength = name.Length;
		switch (EncodingLabels.Classify(name, let single))
		{
		case .SingleByte:
			detection.mEncoding = single;
		case .Latin1:
			detection.mEncoding = .Latin1;
		case .Ascii:
			detection.mEncoding = .Ascii;
		case .Utf8, .None:
			detection.mEncoding = .Utf8;
		default:
			detection.mEncoding = .Custom;
			detection.mConvert = true;
		}
		return detection;
	}

	public static void AppendUndecided(String message, int maxTokenBytes)
	{
		message.AppendF("The declaration is longer than MaxTokenBytes ({})", maxTokenBytes);
	}
}

static class EncodingTests
{
	static TextEncoding[?] sWide = .(.Utf16LE, .Utf16BE, .Utf32LE, .Utf32BE);

	/// `text` in `encoding`, after its byte order mark when `bom`.
	static void Encode(StringView text, TextEncoding encoding, bool bom, List<uint8> output)
	{
		if (bom)
			Test.Assert(Encoder.Encode("\u{FEFF}", encoding, output) == -1);
		Test.Assert(Encoder.Encode(text, encoding, output) == -1);
	}

	static StringView View(List<uint8> bytes) => .((char8*)bytes.Ptr, bytes.Count);

	/// Appends one UTF-16 code unit as it is (a surrogate on its own).
	static void Unit(List<uint8> output, uint16 unit, bool bigEndian)
	{
		output.Add(bigEndian ? (uint8)(unit >> 8) : (uint8)unit);
		output.Add(bigEndian ? (uint8)unit : (uint8)(unit >> 8));
	}

	/// Decodes `input` in pieces of `piece` bytes into a destination of `room` bytes at a time, as a
	/// stream does; the error's message, if any, goes to `error`.
	static bool DecodeInPieces(TextEncoding encoding, Span<uint8> input, int piece, int room, String output, String error)
	{
		var decoder = Decoder(encoding);
		let pending = scope List<uint8>();
		int fed = 0;
		uint8[64] dst = ?;
		while (true)
		{
			int count = Math.Min(piece, input.Length - fed);
			pending.AddRange(Span<uint8>(input.Ptr + fed, count));
			fed += count;
			bool final = fed == input.Length;
			while (true)
			{
				bool ok = decoder.Decode(pending.Ptr, pending.Count, final, &dst, Math.Min(room, 64), let consumed, let produced, let message);
				output.Append((char8*)&dst, produced);
				if (consumed > 0)
					pending.RemoveRange(0, consumed);
				if (!ok)
				{
					error.Set(message);
					return false;
				}
				if (consumed == 0 && produced == 0)
					break;
			}
			if (final)
				return pending.Count == 0;
		}
	}

	[Test]
	public static void Tables_EveryByteBothWays()
	{
		for (int e = (int)TextEncoding.Ibm866; e <= (int)TextEncoding.Windows1258; e++)
		{
			TextEncoding encoding = (.)e;
			uint16* table = SingleByteTables.Get(encoding);
			Test.Assert(table != null);
			var decoder = Decoder(encoding);
			for (int b = 0; b < 256; b++)
			{
				uint8 byte = (uint8)b;
				uint8[8] dst = ?;
				bool ok = decoder.Decode(&byte, 1, true, &dst, 8, let consumed, let produced, let error);
				if (b >= 0x80 && table[b - 0x80] == 0)
				{
					Test.Assert(!ok && consumed == 0 && produced == 0);
					let message = scope String();
					Decoder.AppendError(message, error, encoding, "", byte);
					Test.Assert(message == scope $"The byte 0x{b:X2} is not defined in the encoding `{encoding.Name}`");
					continue;
				}
				Test.Assert(ok && consumed == 1);
				uint32 cp = (uint32)Utf8.Decode((char8*)&dst, 0, let length);
				Test.Assert(length == produced && cp == (b < 0x80 ? (uint32)b : table[b - 0x80]));
				Test.Assert(Encoder.CanEncode((char32)cp, encoding));
				let back = scope List<uint8>();
				Test.Assert(Encoder.Encode(StringView((char8*)&dst, produced), encoding, back) == -1);
				// The byte, or the first byte with the same code point (a table may map two bytes to one)
				Test.Assert(back.Count == 1 && (back[0] == byte || table[back[0] - 0x80] == cp));
			}
			// A character no table holds
			Test.Assert(!Encoder.CanEncode('\u{1F600}', encoding));
			Test.Assert(Encoder.Encode("ok\u{1F600}", encoding, scope .()) == 2);
		}
		// Latin-1: bytes are code points, both ways
		for (int b = 0x80; b < 0x100; b++)
		{
			uint8 byte = (uint8)b;
			uint8[4] dst = ?;
			Test.Assert(Decoder(.Latin1).Decode(&byte, 1, true, &dst, 4, ?, ?, ?));
			Test.Assert((uint32)Utf8.Decode((char8*)&dst, 0, ?) == (uint32)b);
		}
		Test.Assert(Encoder.Encode("é\u{100}", .Latin1, scope .()) == 2 && Encoder.Encode("aé", .Ascii, scope .()) == 1);
	}

	static void DecodesTo(TextEncoding encoding, StringView bytes, StringView expected)
	{
		let output = scope String();
		let error = scope String();
		Test.Assert(DecodeInPieces(encoding, .((uint8*)bytes.Ptr, bytes.Length), bytes.Length, 64, output, error));
		Test.Assert(output == expected);
	}

	[Test]
	public static void Tables_KnownValues()
	{
		DecodesTo(.Windows1251, "\xCF\xF0\xE8\xE2\xE5\xF2", "Привет");
		DecodesTo(.Windows1252, "\x80\x93q\x94", "€“q”");
		DecodesTo(.Koi8R, "\xF0\xD2\xC9\xD7\xC5\xD4", "Привет");
		DecodesTo(.Iso8859_15, "\xA4", "€");
		DecodesTo(.Iso8859_2, "\xB1", "ą");
		DecodesTo(.Macintosh, "\x80", "Ä");
		// ISO-8859-9 and -11 have C1 controls at 0x80-0x9F (WHATWG reads them as windows-1254 and -874)
		DecodesTo(.Iso8859_9, "\xD0\x85", "Ğ\u{85}");
		DecodesTo(.Windows1254, "\xD0\x85", "Ğ…");
		DecodesTo(.Iso8859_11, "\xA1", "ก");
		DecodesTo(.Latin1, "\x80\xE9", "\u{80}é");
		let output = scope String();
		let error = scope String();
		StringView undefined = "a\xAA";
		Test.Assert(!DecodeInPieces(.Windows1253, .((uint8*)undefined.Ptr, 2), 2, 64, output, error) && output == "a");
		StringView high = "a\xE9";
		Test.Assert(!DecodeInPieces(.Ascii, .((uint8*)high.Ptr, 2), 2, 64, output, error));
	}

	[Test]
	public static void Labels()
	{
		TextEncoding encoding;
		Test.Assert(TextEncoding.FromLabel("CP1251", out encoding) && encoding == .Windows1251);
		Test.Assert(TextEncoding.FromLabel("windows-1252", out encoding) && encoding == .Windows1252);
		Test.Assert(TextEncoding.FromLabel("Latin1", out encoding) && encoding == .Latin1);
		Test.Assert(TextEncoding.FromLabel("ISO-8859-1", out encoding) && encoding == .Latin1);
		Test.Assert(TextEncoding.FromLabel("us-ascii", out encoding) && encoding == .Ascii);
		Test.Assert(TextEncoding.FromLabel("TIS-620", out encoding) && encoding == .Iso8859_11);
		Test.Assert(TextEncoding.FromLabel("iso-8859-8-i", out encoding) && encoding == .Iso8859_8);
		Test.Assert(TextEncoding.FromLabel("UTF-16BE", out encoding) && encoding == .Utf16BE);
		Test.Assert(TextEncoding.FromLabel("utf8", out encoding) && encoding == .Utf8);
		Test.Assert(!TextEncoding.FromLabel("utf-16", out encoding) && EncodingLabels.Classify("UTF-16", ?) == .Utf16);
		Test.Assert(!TextEncoding.FromLabel("x-unknown", out encoding) && EncodingLabels.Classify("x-unknown", ?) == .Unknown);
		Test.Assert(EncodingLabels.Classify("", ?) == .None);
		Test.Assert(TextEncoding.Utf16LE.IsWide && !TextEncoding.Latin1.IsWide && TextEncoding.Koi8R.IsSingleByte && !TextEncoding.Utf8.IsSingleByte);
	}

	static void Detects(StringView prefix, TextEncoding encoding, int skip, bool utf8Bom = false, bool undeclared = false)
	{
		switch (Bom.Detect(prefix))
		{
		case .Ok(let detection):
			Test.Assert(detection.mEncoding == encoding && detection.mSkip == skip && detection.mUtf8Bom == utf8Bom && detection.mUndeclared == undeclared);
		case .Err:
			Test.FatalError("rejected");
		}
	}

	static void Rejects(StringView prefix, StringView message)
	{
		Test.Assert(Bom.Detect(prefix) case .Err(let error) && error.mKind == .UnsupportedEncoding && error.mMessage == message);
	}

	[Test]
	public static void Bom_Detect()
	{
		Detects("\x00\x00\xFE\xFFx", .Utf32BE, 4);
		Detects("\xFF\xFE\x00\x00", .Utf32LE, 4);
		Detects("\xFE\xFF\x00<", .Utf16BE, 2);
		Detects("\xFF\xFE<\x00", .Utf16LE, 2);
		Detects("\xEF\xBB\xBF<a>", .Utf8, 0, true);
		Detects("\x00\x00\x00<", .Utf32BE, 0);
		Detects("{\x00\x00\x00", .Utf32LE, 0);
		Detects("\x00{\x00\"", .Utf16BE, 0);
		Detects("{\x00\"\x00", .Utf16LE, 0);
		Detects("<a/>", .Utf8, 0, false, true);
		Detects("a", .Utf8, 0, false, true);
		Detects("", .Utf8, 0, false, true);
		Rejects("+/v8<a/>", "UTF-7 is not supported");
		Rejects("\x4C\x6F\xA7\x94", "EBCDIC encodings are not supported");
		Rejects("\x00\x00\xFF\xFE", "UCS-4 in the unusual byte orders 2143 and 3412 is not supported");
		Rejects("\x00\x00<\x00", "UCS-4 in the unusual byte orders 2143 and 3412 is not supported");
	}

	static void DetectsFirst(StringView prefix, TextEncoding encoding, int skip, bool utf8Bom = false, bool undeclared = false)
	{
		let detection = Bom.DetectFirstCharacter(prefix);
		Test.Assert(detection.mEncoding == encoding && detection.mSkip == skip && detection.mUtf8Bom == utf8Bom && detection.mUndeclared == undeclared);
	}

	[Test]
	public static void Bom_DetectFirstCharacter()
	{
		// YAML 1.2.2 §5.2's table, in its order
		DetectsFirst("\x00\x00\xFE\xFF", .Utf32BE, 4);
		DetectsFirst("\x00\x00\x00a", .Utf32BE, 0);
		DetectsFirst("\xFF\xFE\x00\x00", .Utf32LE, 4);
		DetectsFirst("a\x00\x00\x00", .Utf32LE, 0);
		DetectsFirst("\xFE\xFF\x00a", .Utf16BE, 2);
		DetectsFirst("\x00a", .Utf16BE, 0);
		DetectsFirst("\xFF\xFEa\x00", .Utf16LE, 2);
		DetectsFirst("a\x00", .Utf16LE, 0);
		DetectsFirst("\xEF\xBB\xBFa", .Utf8, 0, true);
		DetectsFirst("a: 1", .Utf8, 0, false, true);
		DetectsFirst("", .Utf8, 0, false, true);
		// What Detect misses: a second character above U+00FF (`a中` in UTF-16)
		DetectsFirst("a\x00\x2D\x4E", .Utf16LE, 0);
		DetectsFirst("\x00a\x4E\x2D", .Utf16BE, 0);
		Detects("a\x00\x2D\x4E", .Utf8, 0, false, true);
	}

	[Test]
	public static void Wide_AsciiRunsMeetOtherCharacters()
	{
		// ASCII runs of every length, then non-ASCII, a surrogate pair, and broken surrogates, decoded in
		// pieces of every size into destinations of several sizes
		for (int pad < 12)
		{
			let filler = scope String()..Append('a', pad);
			let text = scope $"<r>{filler}é\u{1F600}{filler}</r>";
			for (let encoding in sWide)
			{
				let bytes = scope List<uint8>();
				Encode(text, encoding, false, bytes);
				for (int piece = 1; piece <= 31; piece++)
				{
					for (int room in int[?](4, 7, 64))
					{
						let output = scope String();
						Test.Assert(DecodeInPieces(encoding, bytes, piece, room, output, scope .()));
						Test.Assert(output == text);
					}
				}
			}
			for (let bigEndian in bool[?](false, true))
			{
				TextEncoding encoding = bigEndian ? .Utf16BE : .Utf16LE;
				// A high surrogate followed by `x`
				let broken = scope List<uint8>();
				Encode(scope $"<r>{filler}", encoding, false, broken);
				Unit(broken, 0xD83D, bigEndian);
				Encode("x</r>", encoding, false, broken);
				let output = scope String();
				let error = scope String();
				Test.Assert(!DecodeInPieces(encoding, broken, 3, 64, output, error));
				Test.Assert(error == "A UTF-16 high surrogate without its low surrogate" && output == scope $"<r>{filler}");
				// A lone low surrogate
				let low = scope List<uint8>();
				Encode("a", encoding, false, low);
				Unit(low, 0xDC00, bigEndian);
				Test.Assert(!DecodeInPieces(encoding, low, 1, 64, scope .(), error) && error == "A UTF-16 low surrogate without its high surrogate");
				// A high surrogate at the very end
				let cut = scope List<uint8>();
				Encode("ab", encoding, false, cut);
				Unit(cut, 0xD83D, bigEndian);
				Test.Assert(!DecodeInPieces(encoding, cut, 1, 64, scope .(), error) && error == "A UTF-16 high surrogate without its low surrogate");
				// An odd byte at the end
				let odd = scope List<uint8>();
				Encode(scope $"<r>{filler}</r>", encoding, false, odd);
				odd.Add(0x20);
				Test.Assert(!DecodeInPieces(encoding, odd, 5, 64, scope .(), error) && error == "The input ends in the middle of a UTF-16 code unit");
			}
		}
		// UTF-32 beyond U+10FFFF and surrogates
		uint8[?] beyond = .(0x00, 0x00, 0x11, 0x00);
		let message = scope String();
		Test.Assert(!DecodeInPieces(.Utf32LE, .(&beyond, 4), 4, 64, scope .(), message) && message == "A UTF-32 code unit beyond U+10FFFF");
		uint8[?] surrogate = .(0x00, 0x00, 0xD8, 0x00);
		Test.Assert(!DecodeInPieces(.Utf32BE, .(&surrogate, 4), 4, 64, scope .(), message) && message == "A surrogate code point in UTF-32");
		uint8[?] partial = .(0x41, 0x00, 0x00, 0x00, 0x42, 0x00);
		Test.Assert(!DecodeInPieces(.Utf32LE, .(&partial, 6), 2, 64, scope .(), message) && message == "The input ends in the middle of a UTF-32 code unit");
	}

	[Test]
	public static void Wide_SurrogatePairsSplitAtEveryBoundary()
	{
		let text = scope String();
		for (int i < 20)
			text.AppendF("{}\u{1F600}x\u{10000}\u{10FFFF}", i);
		for (let encoding in sWide)
		{
			let bytes = scope List<uint8>();
			Encode(text, encoding, false, bytes);
			for (int piece = 1; piece <= 31; piece++)
			{
				let output = scope String();
				Test.Assert(DecodeInPieces(encoding, bytes, piece, 5, output, scope .()));
				Test.Assert(output == text);
			}
		}
	}

	/// Reads every byte through the cursor one at a time, locating every `locateEvery` bytes against
	/// `text` (the UTF-8 text the offsets index).
	static void ReadAll<TCursor, TText>(ref TCursor cursor, StringView text, String output, int locateEvery, out bool failed, out InputError error)
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
				Utf8.LineAndColumn<TText>(text, pos, let expectedLine, let expectedColumn);
				Test.Assert(line == expectedLine && column == expectedColumn);
			}
			output.Append(data[pos]);
			pos++;
		}
		if (cursor.TryGetInputError(out error))
			failed = true;
	}

	/// The memory cursor and the stream cursor (every chunk size up to 31, three buffer sizes) deliver
	/// the same text and the same first error. Returns whether the memory read failed.
	static bool CheckSameAsMemory<TText, TDetect>(StringView input, InputSettings settings, TranscodeSettings transcode, StringView expected = default,
		TextEncoding expectedEncoding = .Utf8) where TText : ITextPolicy where TDetect : IEncodingDetector
	{
		let memoryState = scope TranscodingState();
		var memory = TranscodingByteCursor<TText, TDetect>(input, memoryState, settings, transcode);
		let memoryOutput = scope String();
		ReadAll<TranscodingByteCursor<TText, TDetect>, TText>(ref memory, input, memoryOutput, 0, let memoryFailed, var memoryError);
		let text = scope String(memory.Text);
		if (!memoryFailed)
		{
			// Located against the text the offsets index
			var again = TranscodingByteCursor<TText, TDetect>(input, memoryState, settings, transcode);
			ReadAll<TranscodingByteCursor<TText, TDetect>, TText>(ref again, text, scope .(), 3, ?, ?);
			if (!expected.IsEmpty)
				Test.Assert(memoryOutput == expected);
			Test.Assert(memory.Encoding == expectedEncoding);
		}
		InputErrorKind memoryKind = memoryError.mKind;
		int memoryOffset = (int)memoryError.mOffset;
		int memoryLine = memoryError.mLine;
		int memoryColumn = memoryError.mColumn;
		let memoryMessage = scope String(memoryError.mMessage);
		int start = memoryFailed ? 0 : (Utf8.StartsWithBom(text.Ptr, text.Length) ? 3 : 0);
		let state = scope TranscodingState();
		for (int chunk = 1; chunk <= 31; chunk++)
		{
			for (int bufferSize in int[?](16, 17, 64))
			{
				var streamSettings = settings;
				streamSettings.mStreamBufferBytes = bufferSize;
				let stream = scope ChunkStream(input, chunk);
				var cursor = TranscodingStreamCursor<TText, TDetect>(stream, state, streamSettings, transcode);
				let output = scope String();
				ReadAll<TranscodingStreamCursor<TText, TDetect>, TText>(ref cursor, text, output, memoryFailed ? 0 : 5, let failed, let error);
				Test.Assert(failed == memoryFailed);
				if (failed)
				{
					Test.Assert(error.mKind == memoryKind && error.mOffset == memoryOffset);
					Test.Assert(error.mLine == memoryLine && error.mColumn == memoryColumn);
					Test.Assert(error.mMessage == memoryMessage);
					// The text before the error was delivered, unless the error was in the first buffer
					if (!output.IsEmpty)
					{
						int textStart = Utf8.StartsWithBom(text.Ptr, text.Length) ? 3 : 0;
						Test.Assert(output == text.Substring(textStart, Math.Max(memoryOffset - textStart, 0)));
					}
				}
				else
				{
					Test.Assert(output == memoryOutput && cursor.Encoding == expectedEncoding);
					Test.Assert(output == text.Substring(start));
				}
			}
		}
		return memoryFailed;
	}

	static void Sample(String text)
	{
		for (int i < 6)
			text.AppendF("<item n=\"{}\">caf\u{E9} \u{1F600}\r\n\tna\u{EF}ve</item>\n", i);
	}

	[Test]
	public static void Cursors_WideEncodingsStreamAsInMemory()
	{
		InputSettings settings = default;
		TranscodeSettings transcode = default;
		let text = scope String();
		Sample(text);
		for (let encoding in sWide)
		{
			for (let bom in bool[?](true, false))
			{
				let bytes = scope List<uint8>();
				Encode(text, encoding, bom, bytes);
				Test.Assert(!CheckSameAsMemory<PlainUtf8Text, BomDetector>(View(bytes), settings, transcode, text, encoding));
				Test.Assert(!CheckSameAsMemory<KdlLikeText, BomDetector>(View(bytes), settings, transcode, text, encoding));
			}
		}
		// UTF-8, with and without a BOM
		Test.Assert(!CheckSameAsMemory<PlainUtf8Text, BomDetector>(text, settings, transcode, text, .Utf8));
		let withBom = scope $"\u{FEFF}{text}";
		Test.Assert(!CheckSameAsMemory<KdlLikeText, BomDetector>(withBom, settings, transcode, text, .Utf8));
		// A BOM rejected
		settings.mBom = .Reject;
		Test.Assert(CheckSameAsMemory<PlainUtf8Text, BomDetector>(withBom, settings, transcode));
	}

	[Test]
	public static void Cursors_ErrorsAreTheSameAndInUtf8Offsets()
	{
		InputSettings settings = default;
		TranscodeSettings transcode = default;
		let text = scope String();
		Sample(text);
		for (let encoding in sWide)
		{
			// A code point the policy bans, late: located in the UTF-8 text
			let banned = scope List<uint8>();
			Encode(scope $"{text}x\u{200E}y", encoding, true, banned);
			Test.Assert(CheckSameAsMemory<KdlLikeText, BomDetector>(View(banned), settings, transcode));
			let state = scope TranscodingState();
			var memory = TranscodingByteCursor<KdlLikeText, BomDetector>(View(banned), state, settings, transcode);
			char8* data = null;
			int windowStart = 0;
			int end = 0;
			Test.Assert(memory.Begin(ref data, ref windowStart, ref end) case .Err(let error));
			Test.Assert(error.mKind == .InvalidChar && error.mOffset == text.Length + 1 && error.mLength == 3);
			// An input cut in the middle of a code unit
			let odd = scope List<uint8>();
			Encode(text, encoding, true, odd);
			odd.Add(0x41);
			Test.Assert(CheckSameAsMemory<PlainUtf8Text, BomDetector>(View(odd), settings, transcode));
		}
		// An unpaired surrogate in UTF-16, early and late
		for (let late in bool[?](false, true))
		{
			let bad = scope List<uint8>();
			Encode(late ? text : "<a>", .Utf16LE, true, bad);
			Unit(bad, 0xD800, false);
			Encode("</a>", .Utf16LE, false, bad);
			Test.Assert(CheckSameAsMemory<PlainUtf8Text, BomDetector>(View(bad), settings, transcode));
			let state = scope TranscodingState();
			var memory = TranscodingByteCursor<PlainUtf8Text, BomDetector>(View(bad), state, settings, transcode);
			char8* data = null;
			int windowStart = 0;
			int end = 0;
			Test.Assert(memory.Begin(ref data, ref windowStart, ref end) case .Err(let error));
			Test.Assert(error.mKind == .InvalidEncoding && error.mOffset == (late ? text.Length : 3));
			Test.Assert(error.mMessage == "A UTF-16 high surrogate without its low surrogate");
		}
		// Rejected by detection
		Test.Assert(CheckSameAsMemory<PlainUtf8Text, BomDetector>("+/v8<a/>", settings, transcode));
	}

	[Test]
	public static void Cursors_DeclaredEncodings()
	{
		InputSettings settings = default;
		TranscodeSettings transcode = default;
		// A table encoding, declared past the first prefix (detection grows it)
		StringView latin = "@windows-1251\n<a b=\"\xCF\xF0\">\xE8\xE2\xE5\xF2</a>\n";
		CheckSameAsMemory<PlainUtf8Text, AtDetector>(latin, settings, transcode, "@windows-1251\n<a b=\"Пр\">ивет</a>\n", .Windows1251);
		// A byte the table leaves undefined, on line 2: named with the declared name, in UTF-8 offsets
		StringView undefined = "@WINDOWS-1253\n\xE1\xAA";
		Test.Assert(CheckSameAsMemory<PlainUtf8Text, AtDetector>(undefined, settings, transcode));
		let state = scope TranscodingState();
		var memory = TranscodingByteCursor<PlainUtf8Text, AtDetector>(undefined, state, settings, transcode);
		char8* data = null;
		int windowStart = 0;
		int end = 0;
		Test.Assert(memory.Begin(ref data, ref windowStart, ref end) case .Err(let error));
		Test.Assert(error.mKind == .InvalidEncoding && error.mLine == 2 && error.mColumn == 2 && error.mOffset == 14 + 2);
		Test.Assert(error.mMessage == "The byte 0xAA is not defined in the encoding `WINDOWS-1253`");
		// US-ASCII
		Test.Assert(CheckSameAsMemory<PlainUtf8Text, AtDetector>("@us-ascii\nab\xE9", settings, transcode));
		// A declaration longer than MaxTokenBytes
		settings.mMaxTokenBytes = 16;
		Test.Assert(CheckSameAsMemory<PlainUtf8Text, AtDetector>("@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nx", settings, transcode));
		var limited = TranscodingByteCursor<PlainUtf8Text, AtDetector>("@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nx", state, settings, transcode);
		Test.Assert(limited.Begin(ref data, ref windowStart, ref end) case .Err(let tooLong));
		Test.Assert(tooLong.mKind == .ResourceLimitExceeded && tooLong.mMessage == "The declaration is longer than MaxTokenBytes (16)");
	}

	static bool Rot13(StringView name, Span<uint8> input, String output)
	{
		if (name != "x-rot13")
			return false;
		// The declaration line stays; the rest is rotated
		int i = 0;
		while (i < input.Length && input[i] != '\n')
			output.Append((char8)input[i++]);
		for (; i < input.Length; i++)
		{
			char8 c = (char8)input[i];
			if (c >= 'a' && c <= 'z')
				c = (char8)('a' + (c - 'a' + 13) % 26);
			output.Append(c);
		}
		return true;
	}

	[Test]
	public static void Cursors_ConverterAndFallback()
	{
		InputSettings settings = default;
		TranscodeSettings transcode = default;
		// The converter takes the whole input
		transcode.mConverter = scope => Rot13;
		CheckSameAsMemory<PlainUtf8Text, AtDetector>("@x-rot13\nuryyb jbeyq", settings, transcode, "@x-rot13\nhello world", .Custom);
		// A name nothing takes: the error is at the name
		Test.Assert(CheckSameAsMemory<PlainUtf8Text, AtDetector>("@x-other\nabc", settings, transcode));
		let state = scope TranscodingState();
		var memory = TranscodingByteCursor<PlainUtf8Text, AtDetector>("@x-other\nabc", state, settings, transcode);
		char8* data = null;
		int windowStart = 0;
		int end = 0;
		Test.Assert(memory.Begin(ref data, ref windowStart, ref end) case .Err(let error));
		Test.Assert(error.mKind == .UnsupportedEncoding && error.mOffset == 1 && error.mLength == 7 && error.mMessage == "The encoding `x-other` is not supported");

		// The fallback reads undeclared input that is not UTF-8 as Windows-1252, the whole stream first
		transcode = default;
		transcode.mFallback = .Windows1252;
		CheckSameAsMemory<PlainUtf8Text, BomDetector>("<a>caf\xE9 \x80</a>", settings, transcode, "<a>café €</a>", .Windows1252);
		// UTF-8 stays UTF-8
		CheckSameAsMemory<PlainUtf8Text, BomDetector>("<a>caf\u{E9}</a>", settings, transcode, "<a>caf\u{E9}</a>", .Utf8);
		// Without the fallback it is invalid UTF-8
		transcode.mFallback = .None;
		Test.Assert(CheckSameAsMemory<PlainUtf8Text, BomDetector>("<a>caf\xE9</a>", settings, transcode));
	}

	[Test]
	public static void Cursors_Limits()
	{
		InputSettings settings = default;
		TranscodeSettings transcode = default;
		let text = scope String();
		Sample(text);
		let bytes = scope List<uint8>();
		Encode(text, .Utf16LE, true, bytes);
		// MaxTokenBytes bounds the UTF-8 window as for any stream: this reader asks for one byte at a time
		settings.mMaxTokenBytes = 8;
		Test.Assert(!CheckSameAsMemory<PlainUtf8Text, BomDetector>(View(bytes), settings, transcode, text, .Utf16LE));
		// MaxInputBytes counts the input's bytes
		settings = default;
		settings.mMaxInputBytes = 10;
		let state = scope TranscodingState();
		var memory = TranscodingByteCursor<PlainUtf8Text, BomDetector>(View(bytes), state, settings, transcode);
		char8* data = null;
		int windowStart = 0;
		int end = 0;
		Test.Assert(memory.Begin(ref data, ref windowStart, ref end) case .Err(let error) && error.mKind == .ResourceLimitExceeded);
		let stream = scope ChunkStream(View(bytes), 7);
		var streamed = TranscodingStreamCursor<PlainUtf8Text, BomDetector>(stream, state, settings, transcode);
		Test.Assert(streamed.Begin(ref data, ref windowStart, ref end) case .Err(let streamError) && streamError.mKind == .ResourceLimitExceeded);
	}
}
