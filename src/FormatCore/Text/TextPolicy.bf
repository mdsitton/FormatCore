using System;
using internal FormatCore;

namespace FormatCore;

/// A format's character rules, at compile time: which code points may appear in a document beyond
/// UTF-8 well-formedness, and which byte sequences are newlines. Every member is static, so a struct
/// that implements it is passed as a generic argument (`Utf8.FindInvalid<KdlText>`,
/// `LineCounter<KdlText>`) and its members specialize and inline into the caller. Mark the members
/// `[Inline]`: without LTO (Debug, macOS) that is what keeps them out of the hot loops.
internal interface ITextPolicy
{
	/// Whether input is validated before the reader sees it (every byte of a memory input, each refill
	/// of a stream): true for TOML, KDL and XML, false for JSON, which checks UTF-8 in its string scan
	/// because only strings may hold non-ASCII bytes.
	static bool ValidatesUpFront { get; }

	/// Whether the 8 ASCII-or-not bytes of `word` need no check at all: all ASCII and none banned. Exact
	/// in the negative direction only (false sends the word to the byte checks).
	static bool IsPlainWord(uint64 word);

	/// Whether the ASCII byte `b` (below 0x80) may appear.
	static bool AllowsAscii(uint8 b);

	/// Whether the policy bans any code point at or above U+0080 (when false, well-formed UTF-8 is
	/// accepted without decoding).
	static bool BansCodePoints { get; }

	/// Whether the well-formed code point `cp` (≥ U+0080) may appear. Only called when BansCodePoints.
	static bool AllowsCodePoint(uint32 cp);

	/// Appends the message for a code point the policy bans (ASCII or not).
	static void AppendBanned(String message, uint32 cp);

	/// The byte length of the newline at `text[pos]` (`pos < end`), or 0: LF, CR and CRLF (one
	/// newline) everywhere, plus whatever else the format counts.
	static int NewlineLength(char8* text, int pos, int end);

	/// Nonzero when `word` may hold the first byte of a newline (false positives allowed, none missed).
	static uint64 MayHoldNewline(uint64 word);

	/// Whether LF, CR and CRLF are the only newlines, so that a word's newlines can be counted at once.
	static bool OnlyAsciiNewlines { get; }
}

/// UTF-8 with no further bans, LF/CR/CRLF newlines, validated up front (TOML's rules; a format that
/// validates while scanning, like JSON, defines its own with ValidatesUpFront false).
internal struct PlainUtf8Text : ITextPolicy
{
	public static bool ValidatesUpFront
	{
		[Inline]
		get => true;
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
		message.Append("The character ");
		Hex.AppendCodePointName(message, cp);
		message.Append(" is not allowed");
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
