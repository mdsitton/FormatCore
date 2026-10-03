using System;
using internal FormatCore;

namespace FormatCore;

/// What a cursor reports about the input itself, apart from the grammar. Each format maps these to
/// its own error kinds in one switch.
internal enum InputErrorKind : uint8
{
	/// Bytes that are not well-formed UTF-8.
	InvalidUtf8,
	/// A well-formed code point the format's text policy bans.
	InvalidChar,
	/// The input is in an encoding the format does not read (UTF-16 or UTF-32 by its BOM or zero bytes).
	UnsupportedEncoding,
	/// A byte order mark where InputSettings.Bom rejects it.
	ByteOrderMark,
	/// MaxInputBytes or MaxTokenBytes exceeded.
	ResourceLimitExceeded,
	/// Reading the input failed.
	IoError
}

/// An input error with its location. Like a format's parse error it owns nothing: `mMessage` views a
/// per-thread buffer that the next InputError on the thread replaces. A format turns it into its own
/// error at once (its constructor copies the message into its own buffer).
internal struct InputError
{
	static LazyTLS<String> sMessageBuffer = new .() ~ delete _;

	public InputErrorKind mKind;
	public StringView mMessage;
	public int32 mLine;
	public int32 mColumn;
	public int64 mOffset;
	public int32 mLength;

	/// @brief An error at a location.
	/// @param kind The kind.
	/// @param message The message (copied).
	/// @param line 1-based line (0: none).
	/// @param column 1-based column in code points.
	/// @param offset Byte offset.
	/// @param length Length of the offending bytes.
	public this(InputErrorKind kind, StringView message, int line, int column, int64 offset, int length)
	{
		mKind = kind;
		mMessage = PerThreadText.Store(sMessageBuffer.Value, message);
		mLine = (int32)line;
		mColumn = (int32)column;
		mOffset = offset;
		mLength = (int32)length;
	}
}

/// The per-thread text buffers error carriers keep their messages in.
internal static class PerThreadText
{
	/// @brief Copies `text` into `buffer` and returns a view of it. The text may itself be a view of the
	/// buffer (an error rebuilt from a previous one's message).
	/// @param buffer The per-thread buffer.
	/// @param text The text.
	/// @return A view of the buffer.
	public static StringView Store(String buffer, StringView text)
	{
		char8* start = buffer.Ptr;
		if (text.Ptr >= start && text.Ptr < start + buffer.Length)
		{
			let copy = scope String(text);
			buffer.Set(copy);
		}
		else
			buffer.Set(text);
		return buffer;
	}
}

/// Whether a leading UTF-8 byte order mark is skipped or is an error.
internal enum BomPolicy : uint8
{
	/// Skip one (offsets stay raw; lines and columns start after it).
	Skip,
	/// Report InputErrorKind.ByteOrderMark (JsonReadConfig.AllowBom off).
	Reject
}

/// The cursor-level settings every format's read config has, built by the format from its config.
internal struct InputSettings
{
	/// Fail when the input is longer (0: no limit).
	public int mMaxInputBytes;
	/// Fail when one construct plus the lookahead the reader needs is longer (streams; 0: no limit).
	public int mMaxTokenBytes;
	/// The stream buffer's first size (0: 64 KiB); at least 16, at most MaxTokenBytes.
	public int mStreamBufferBytes;
	public BomPolicy mBom;
	/// Whether UTF-16 and UTF-32 input is left to fail as invalid UTF-8 instead of being reported as
	/// such (UnsupportedEncoding).
	public bool mIgnoreWideEncodings;
	/// The format's name for messages ("JSON must be UTF-8"); empty: "the input".
	public StringView mFormatName;

	/// @brief The stream buffer's first size: StreamBufferBytes (0: 64 KiB), at least 16, and with a
	/// MaxTokenBytes no more than it (a construct that would exceed the limit then always comes to
	/// Fill, which checks it).
	/// @return The size in bytes.
	public int StreamBufferSize
	{
		get
		{
			int size = mStreamBufferBytes > 0 ? Math.Max(mStreamBufferBytes, 16) : 64 * 1024;
			if (mMaxTokenBytes > 0)
				size = Math.Min(size, Math.Max(mMaxTokenBytes, 16));
			return size;
		}
	}
}

/// The checks every input gets before its first byte is read (JsonBeef's JsonInputStart, generalized).
internal static class InputStart
{
	/// @brief The name of the UTF-16 or UTF-32 encoding the first bytes show (a BOM, or the zero bytes
	/// of ASCII characters in 16- or 32-bit units, RFC 4627 §3), or "" when they show none.
	/// @param data The input's first bytes.
	/// @param length How many there are (up to 4 are looked at).
	/// @return The encoding's name, or "".
	public static StringView DetectWideEncoding(char8* data, int length)
	{
		uint8* b = (uint8*)data;
		if (length >= 4 && b[0] == 0 && b[1] == 0 && b[2] == 0xFE && b[3] == 0xFF)
			return "UTF-32BE";
		if (length >= 4 && b[0] == 0xFF && b[1] == 0xFE && b[2] == 0 && b[3] == 0)
			return "UTF-32LE";
		if (length >= 2 && b[0] == 0xFE && b[1] == 0xFF)
			return "UTF-16BE";
		if (length >= 2 && b[0] == 0xFF && b[1] == 0xFE)
			return "UTF-16LE";
		if (length >= 4)
		{
			if (b[0] == 0 && b[1] == 0 && b[2] == 0 && b[3] != 0)
				return "UTF-32BE";
			if (b[0] != 0 && b[1] == 0 && b[2] == 0 && b[3] == 0)
				return "UTF-32LE";
			if (b[0] == 0 && b[1] != 0 && b[2] == 0 && b[3] != 0)
				return "UTF-16BE";
			if (b[0] != 0 && b[1] == 0 && b[2] != 0 && b[3] == 0)
				return "UTF-16LE";
		}
		return "";
	}

	/// @brief The offset of the first content byte of `data[0 ..< length]` (3 after a skipped BOM), or
	/// the error: a wide encoding (when detected), a rejected BOM.
	/// @param data The input's first bytes (all of them, or at least 4).
	/// @param length How many there are.
	/// @param settings The settings.
	/// @return The offset, or the error.
	public static Result<int, InputError> Check(char8* data, int length, InputSettings settings)
	{
		if (!settings.mIgnoreWideEncodings)
		{
			let wide = DetectWideEncoding(data, length);
			if (!wide.IsEmpty)
			{
				let message = scope String();
				message.AppendF("The input is {} ({} must be UTF-8): transcode it first", wide,
					settings.mFormatName.IsEmpty ? "the input" : settings.mFormatName);
				return .Err(InputError(.UnsupportedEncoding, message, 1, 1, 0, 0));
			}
		}
		if (Utf8.StartsWithBom(data, length))
		{
			if (settings.mBom == .Reject)
				return .Err(InputError(.ByteOrderMark, "A byte order mark (U+FEFF) is not allowed", 1, 1, 0, 3));
			return 3;
		}
		return 0;
	}
}
