using System;
using internal FormatCore;

namespace FormatCore.Tests;

/// KDL's rules as a text policy (KdlChar's FindInvalid bans and newline set), for testing the generic
/// paths with a format that bans code points and has multi-byte newlines.
struct KdlLikeText : ITextPolicy
{
	public static bool ValidatesUpFront
	{
		[Inline]
		get => true;
	}

	/// ASCII from 0x20 to 0x7E, tab, LF, VT, FF, CR: bytes 0x09-0x0D and 0x20-0x7E.
	[Inline]
	public static bool IsPlainWord(uint64 word)
	{
		if (!Swar.IsAscii(word))
			return false;
		// Below 0x20 only 0x09-0x0D; no DEL
		uint64 low = Swar.BytesBelowSpace(word);
		uint64 control = low & ~(Swar.BytesEqual(word, 0x09) | Swar.BytesEqual(word, 0x0A) | Swar.BytesEqual(word, 0x0B) |
			Swar.BytesEqual(word, 0x0C) | Swar.BytesEqual(word, 0x0D));
		return control == 0 && Swar.BytesEqual(word, 0x7F) == 0;
	}

	[Inline]
	public static bool AllowsAscii(uint8 b) => !(b <= 0x08 || (b >= 0x0E && b <= 0x1F) || b == 0x7F);

	public static bool BansCodePoints
	{
		[Inline]
		get => true;
	}

	public static bool AllowsCodePoint(uint32 c)
	{
		return !(c == 0x200E || c == 0x200F || (c >= 0x202A && c <= 0x202E) || (c >= 0x2066 && c <= 0x2069) || c == 0xFEFF);
	}

	public static void AppendBanned(String message, uint32 cp)
	{
		if (cp == 0xFEFF)
		{
			message.Append("A byte order mark (U+FEFF) may only appear at the start of a document");
			return;
		}
		message.Append("The code point ");
		Hex.AppendCodePointName(message, cp);
		message.Append(" is not allowed in a KDL document");
	}

	[Inline]
	public static int NewlineLength(char8* text, int pos, int end)
	{
		uint8* data = (uint8*)text;
		uint8 b = data[pos];
		switch (b)
		{
		case 0x0A, 0x0B, 0x0C:
			return 1;
		case 0x0D:
			return (pos + 1 < end && data[pos + 1] == 0x0A) ? 2 : 1;
		case 0xC2:
			return (pos + 1 < end && data[pos + 1] == 0x85) ? 2 : 0;
		case 0xE2:
			return (pos + 2 < end && data[pos + 1] == 0x80 && (data[pos + 2] == 0xA8 || data[pos + 2] == 0xA9)) ? 3 : 0;
		default:
			return 0;
		}
	}

	[Inline]
	public static uint64 MayHoldNewline(uint64 word) => Swar.BytesBelow0E(word) | Swar.BytesEqual(word, 0xC2) | Swar.BytesEqual(word, 0xE2);

	public static bool OnlyAsciiNewlines
	{
		[Inline]
		get => false;
	}
}

/// JSON's rules: nothing validated up front (the reader checks strings), LF/CR/CRLF.
struct JsonLikeText : ITextPolicy
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

/// A stream that returns at most `chunk` bytes per read, and optionally fails after `failAfter` bytes.
class ChunkStream : System.IO.Stream
{
	Span<uint8> mData;
	int mPos;
	int mChunk;
	int mFailAfter;

	public this(StringView data, int chunk, int failAfter = -1)
	{
		mData = .((uint8*)data.Ptr, data.Length);
		mChunk = Math.Max(chunk, 1);
		mFailAfter = failAfter;
	}

	public override int64 Position
	{
		get => mPos;
		set => mPos = (int)value;
	}

	public override int64 Length => mData.Length;
	public override bool CanRead => true;
	public override bool CanWrite => false;

	public override Result<int> TryRead(Span<uint8> data)
	{
		if (mFailAfter >= 0 && mPos >= mFailAfter)
			return .Err;
		int limit = mFailAfter >= 0 ? Math.Min(mData.Length, mFailAfter) : mData.Length;
		int count = Math.Min(Math.Min(data.Length, mChunk), limit - mPos);
		if (count <= 0)
			return mFailAfter >= 0 && limit < mData.Length ? .Err : .Ok(0);
		Internal.MemCpy(data.Ptr, mData.Ptr + mPos, count);
		mPos += count;
		return count;
	}

	public override Result<int> TryWrite(Span<uint8> data) => .Err;
	public override Result<void> Close() => .Ok;
}
