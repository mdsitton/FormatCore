using System;
using System.Collections;
using internal FormatCore;

namespace FormatCore.Tests;

static class TextTests
{
	static uint64 Word(uint8[8] bytes)
	{
		var bytes;
		uint64 word = 0;
		Internal.MemCpy(&word, &bytes, 8);
		return word;
	}

	static bool Marked(uint64 mask, int i) => ((mask >> (i * 8 + 7)) & 1) != 0;

	[Test]
	public static void Swar_PredicatesAreExactForEveryByteAtEveryPosition()
	{
		uint8[3] fillers = .(0x41, 0x00, 0xC3);
		for (let filler in fillers)
		{
			for (int pos < 8)
			{
				for (int value < 256)
				{
					uint8[8] bytes = .(filler, filler, filler, filler, filler, filler, filler, filler);
					bytes[pos] = (uint8)value;
					uint64 word = Word(bytes);
					uint64 eq = Swar.BytesEqual(word, (uint8)'<');
					uint64 below = Swar.BytesBelowSpace(word);
					uint64 above = Swar.BytesAboveSpace(word);
					uint64 zero = Swar.ZeroBytes(word);
					uint64 nonSpace = Swar.NonSpaceBytes(word);
					bool any0E = false;
					for (int i < 8)
					{
						uint8 b = bytes[i];
						Test.Assert(Marked(eq, i) == (b == (uint8)'<'));
						Test.Assert(Marked(below, i) == (b < 0x20));
						Test.Assert(Marked(above, i) == (b > 0x20));
						Test.Assert(Marked(zero, i) == (b == 0));
						Test.Assert(Marked(nonSpace, i) == !(b == ' ' || b == '\t' || b == '\n' || b == '\r'));
						any0E |= b < 0x0E;
					}
					Test.Assert((Swar.BytesBelow0E(word) != 0) == any0E);
					Test.Assert((eq & ~Swar.High) == 0 && (below & ~Swar.High) == 0 && (above & ~Swar.High) == 0);
					if (eq != 0)
					{
						int first = 0;
						while (bytes[first] != (uint8)'<')
							first++;
						Test.Assert(Swar.FirstByte(eq) == first);
					}
				}
			}
		}
	}

	[Test]
	public static void Swar_CountsDigitsAndCompares()
	{
		StringView digits = "12345678";
		uint64 word = Swar.Load64(digits.Ptr);
		Test.Assert(Swar.AllDigits(word));
		Test.Assert(Swar.ParseEightDigits(word) == 12345678);
		Test.Assert(Swar.ParseEightDigits(Swar.Load64("00000009".Ptr)) == 9);
		Test.Assert(!Swar.AllDigits(Swar.Load64("1234567a".Ptr)));
		Test.Assert(!Swar.AllDigits(Swar.Load64("1234/678".Ptr)));
		Test.Assert(!Swar.AllDigits(Swar.Load64(":2345678".Ptr)));
		Test.Assert(Swar.CountHighBits(0) == 0 && Swar.CountHighBits(Swar.High) == 8);

		char8[24] a = ?;
		char8[24] b = ?;
		for (int length <= 24)
		{
			for (int i < 24)
			{
				a[i] = (char8)('a' + i);
				b[i] = a[i];
			}
			Test.Assert(Swar.EqualBytes(&a, &b, length));
			for (int diff < length)
			{
				b[diff] = '#';
				Test.Assert(!Swar.EqualBytes(&a, &b, length));
				b[diff] = a[diff];
			}
		}
	}

	/// `<`, `&` and bytes below 0x20 (XmlBeef's text stops).
	struct TextStops : IStopSet16
	{
		[Inline]
		public static uint64 Word(uint64 word) => Swar.BytesEqual(word, (uint8)'<') | Swar.BytesEqual(word, (uint8)'&') | Swar.BytesBelowSpace(word);

		[Inline]
		public static bool Byte(uint8 b) => b == (uint8)'<' || b == (uint8)'&' || b < 0x20;

		[Inline]
		public static Mask16 Lanes(Bytes16 bytes)
		{
			// Signed lanes: bytes ≥ 0x80 are below 0x20 too, so they are masked out by an unsigned test
			// here instead: only ASCII text reaches this test's inputs
			return (bytes == Bytes16.Splat((uint8)'<')) | (bytes == Bytes16.Splat((uint8)'&')) | (bytes < Bytes16.Splat(0x20));
		}
	}

	[Test]
	public static void Scan_UntilMatchesTheByteLoop()
	{
		char8[40] text = ?;
		uint8[?] stops = .((uint8)'<', (uint8)'&', 0x00, 0x1F, (uint8)'\n');
		for (int start < 8)
		{
			for (int at = start; at <= 40; at++)
			{
				for (let stop in stops)
				{
					for (int i < 40)
						text[i] = (char8)('a' + i % 26);
					if (at < 40)
						text[at] = (char8)stop;
					Test.Assert(Scan.Until<TextStops>(&text, start, 40) == at);
					Test.Assert(Scan.Until16<TextStops>(&text, start, 40) == at);
					// A window that ends before the stop
					int end = Math.Min(at, 40);
					Test.Assert(Scan.Until<TextStops>(&text, start, end) == end);
				}
			}
		}
	}

	[Test]
	public static void Bytes16_FindsTheFirstStop()
	{
		char8[17] text = ?;
		for (int stop <= 16)
		{
			for (int i < 17)
				text[i] = 'x';
			if (stop < 16)
				text[stop] = '"';
			var mask = (Bytes16.Load(&text) == Bytes16.Splat((uint8)'"')) | (Bytes16.Load(&text) < Bytes16.Splat((uint8)' '));
			Test.Assert(mask.FirstSet() == stop);
		}
		// Bytes ≥ 0x80 compare below a space (signed lanes)
		for (int i < 16)
			text[i] = 'x';
		text[5] = (char8)0xC3;
		var high = Bytes16.Load(&text) < Bytes16.Splat((uint8)' ');
		Test.Assert(high.FirstSet() == 5);
	}

	/// The reference: the offset of the first error and its kind, by the definition (table 3-7 as
	/// ranges of decoded values), with the policy's bans.
	static int ReferenceInvalid<TText>(uint8* data, int length, out InputErrorKind kind) where TText : ITextPolicy
	{
		kind = .InvalidUtf8;
		int i = 0;
		while (i < length)
		{
			uint8 b = data[i];
			if (b < 0x80)
			{
				if (!TText.AllowsAscii(b))
				{
					kind = .InvalidChar;
					return i;
				}
				i++;
				continue;
			}
			int seqLen = b >= 0xC2 && b <= 0xDF ? 2 : b >= 0xE0 && b <= 0xEF ? 3 : b >= 0xF0 && b <= 0xF4 ? 4 : 0;
			if (seqLen == 0 || i + seqLen > length)
				return i;
			uint32 cp = b & (seqLen == 2 ? 0x1Fu : seqLen == 3 ? 0x0Fu : 0x07u);
			for (int j = 1; j < seqLen; j++)
			{
				if ((data[i + j] & 0xC0) != 0x80)
					return i;
				cp = (cp << 6) | (data[i + j] & 0x3F);
			}
			uint32 min = seqLen == 2 ? 0x80 : seqLen == 3 ? 0x800 : 0x10000;
			if (cp < min || (cp >= 0xD800 && cp <= 0xDFFF) || cp > 0x10FFFF)
				return i;
			if (TText.BansCodePoints && !TText.AllowsCodePoint(cp))
			{
				kind = .InvalidChar;
				return i;
			}
			i += seqLen;
		}
		return -1;
	}

	static void CheckAgainstReference<TText>(uint8* data, int length) where TText : ITextPolicy
	{
		let message = scope String();
		int found = Utf8.FindInvalid<TText>((char8*)data, 0, length, message, let kind, let errorLength);
		int expected = ReferenceInvalid<TText>(data, length, let expectedKind);
		Test.Assert(found == expected);
		if (found >= 0)
		{
			Test.Assert(kind == expectedKind);
			Test.Assert(!message.IsEmpty && errorLength >= 1 && found + errorLength <= length);
		}
	}

	[Test]
	public static void Utf8_FindInvalidMatchesTheReferenceOnEveryShortSequence()
	{
		uint8[16] buffer = ?;
		// Every 1- and 2-byte sequence, after a word of ASCII (so the word paths run first)
		for (int i < 8)
			buffer[i] = (uint8)'a';
		for (int b0 < 256)
		{
			buffer[8] = (uint8)b0;
			CheckAgainstReference<PlainUtf8Text>(&buffer, 9);
			CheckAgainstReference<KdlLikeText>(&buffer, 9);
			for (int b1 < 256)
			{
				buffer[9] = (uint8)b1;
				CheckAgainstReference<PlainUtf8Text>(&buffer, 10);
				CheckAgainstReference<KdlLikeText>(&buffer, 10);
			}
		}
		// Every 3-byte sequence with a 3-byte lead, and every lead with a sample of continuations
		for (int b0 = 0xE0; b0 <= 0xEF; b0++)
		{
			for (int b1 < 256)
			{
				for (int b2 < 256)
				{
					buffer[0] = (uint8)b0;
					buffer[1] = (uint8)b1;
					buffer[2] = (uint8)b2;
					CheckAgainstReference<PlainUtf8Text>(&buffer, 3);
				}
			}
		}
		uint8[?] samples = .(0x00, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xFF);
		for (int b0 = 0xC0; b0 < 256; b0++)
		{
			for (let b1 in samples)
			{
				for (let b2 in samples)
				{
					for (let b3 in samples)
					{
						buffer[0] = (uint8)b0;
						buffer[1] = b1;
						buffer[2] = b2;
						buffer[3] = b3;
						CheckAgainstReference<PlainUtf8Text>(&buffer, 4);
						CheckAgainstReference<KdlLikeText>(&buffer, 4);
					}
				}
			}
		}
	}

	[Test]
	public static void Utf8_BannedCodePointsAndMessages()
	{
		let message = scope String();
		StringView text = "plain text, then a bidi mark: \u{200E}!";
		int at = Utf8.FindInvalid<KdlLikeText>(text.Ptr, 0, text.Length, message, var kind, var length);
		Test.Assert(at == text.IndexOf("\u{200E}") && kind == .InvalidChar && length == 3);
		Test.Assert(message == "The code point U+200E is not allowed in a KDL document");
		message.Clear();
		Test.Assert(Utf8.FindInvalid<PlainUtf8Text>(text.Ptr, 0, text.Length, message, ?, ?) == -1);

		StringView del = "abc\x7Fdef";
		Test.Assert(Utf8.FindInvalid<KdlLikeText>(del.Ptr, 0, del.Length, message, out kind, ?) == 3 && kind == .InvalidChar);

		uint8[?] surrogate = .((uint8)'x', 0xED, 0xA0, 0x80);
		message.Clear();
		Test.Assert(Utf8.FindInvalid<PlainUtf8Text>((char8*)&surrogate, 0, 4, message, out kind, out length) == 1);
		Test.Assert(kind == .InvalidUtf8 && length == 2);
		Test.Assert(message == "The bytes 0xED 0xA0 encode a surrogate (U+D800-U+DFFF), which is not valid UTF-8");

		uint8[?] cut = .(0xE2, 0x82);
		message.Clear();
		Test.Assert(Utf8.FindInvalid<PlainUtf8Text>((char8*)&cut, 0, 2, message, out kind, out length) == 0 && length == 2);
		Test.Assert(message == "The UTF-8 sequence starting with 0xE2 is cut off by the end of the input");

		uint8[?] stray = .(0x80);
		message.Clear();
		Utf8.FindInvalid<PlainUtf8Text>((char8*)&stray, 0, 1, message, ?, ?);
		Test.Assert(message == "The byte 0x80 is not valid UTF-8 (a continuation byte without a lead byte)");
	}

	[Test]
	public static void Utf8_SequencesAtEveryCut()
	{
		StringView text = "a\u{E9}b\u{20AC}c\u{1F600}d";
		for (int cut <= text.Length)
		{
			int end = Utf8.CompleteSequencesEnd(text.Ptr, 0, cut);
			// The end is a boundary at or before the cut, and nothing complete is left out
			Test.Assert(end <= cut);
			Test.Assert(Utf8.FindInvalid<PlainUtf8Text>(text.Ptr, 0, end, scope .(), ?, ?) == -1);
			if (end < cut)
				Test.Assert(Utf8.SequenceLength(text[end]) > cut - end);
			// FindInvalid over the cut reports the cut sequence, if any
			int bad = Utf8.FindInvalid<PlainUtf8Text>(text.Ptr, 0, cut, scope .(), ?, ?);
			Test.Assert(bad == (end < cut ? end : -1));
		}
		Test.Assert(Utf8.CountCodePoints(text.Ptr, 0, text.Length) == 7);
		for (int i < text.Length)
		{
			if (((uint8)text[i] & 0xC0) == 0x80)
				continue;
			int length = 0;
			char32 c = Utf8.Decode(text.Ptr, i, out length);
			char8[4] encoded = ?;
			Test.Assert(Utf8.Encode(&encoded, (uint32)c) == length);
			Test.Assert(Swar.EqualBytes(&encoded, text.Ptr + i, length));
			Test.Assert(Utf8.ValidSequenceLength(text.Ptr, i, text.Length) == (length == 1 ? 0 : length));
		}
		let appended = scope String();
		Utf8.Encode(appended, 0x1F600);
		Utf8.Encode(appended, (uint32)'x');
		Test.Assert(appended == "\u{1F600}x");
	}

	[Test]
	public static void Utf8_MaximalSubparts()
	{
		uint8[?] c0 = .(0xC0, 0xAF);
		Test.Assert(Utf8.MaximalSubpartLength((char8*)&c0, 0, 2) == 1);
		uint8[?] ed = .(0xED, 0xA0, 0x80);
		Test.Assert(Utf8.MaximalSubpartLength((char8*)&ed, 0, 3) == 1);
		uint8[?] e2 = .(0xE2, 0x82, 0x41);
		Test.Assert(Utf8.MaximalSubpartLength((char8*)&e2, 0, 3) == 2);
		uint8[?] f0 = .(0xF0, 0x9F, 0x98);
		Test.Assert(Utf8.MaximalSubpartLength((char8*)&f0, 0, 3) == 3);
		Test.Assert(Utf8.FindNoncharacter("ok \u{FDD0}") == 3);
		Test.Assert(Utf8.FindNoncharacter("ok \u{10FFFF}") == 3);
		Test.Assert(Utf8.FindNoncharacter("ok \u{FFFD}") == -1);
	}

	[Test]
	public static void Hex_DigitsAndNames()
	{
		Test.Assert(Hex.DigitValue('0') == 0 && Hex.DigitValue('f') == 15 && Hex.DigitValue('F') == 15 && Hex.DigitValue('g') == 255);
		Test.Assert(Hex.Digits4("00e9".Ptr) == 0xE9 && Hex.Digits4("FFFF".Ptr) == 0xFFFF && Hex.Digits4("12x4".Ptr) > 0xFFFF);
		let text = scope String();
		Hex.AppendCodePointName(text, 0x9);
		text.Append(' ');
		Hex.AppendCodePointName(text, 0x1F600);
		text.Append(' ');
		Hex.Append(text, 0xAB, 1);
		Test.Assert(text == "U+0009 U+1F600 AB");
		text.Clear();
		StringView sample = "\t\u{E9}\u{200B}";
		Hex.AppendCharDescription(text, sample.Ptr, 0, sample.Length, var length);
		text.Append('|');
		Hex.AppendCharDescription(text, sample.Ptr, 1, sample.Length, out length);
		text.Append('|');
		Hex.AppendCharDescription(text, sample.Ptr, 3, sample.Length, out length);
		text.Append('|');
		Hex.AppendCharDescription(text, sample.Ptr, 3, 4, out length);
		Test.Assert(text == "U+0009 (tab)|`\u{E9}`|U+200B|the byte 0xE2");
	}
}
