using System;
using internal FormatCore;

namespace FormatCore;

/// @brief A read error with its location: the carrier the four format libraries share, each under its
/// own name (`public typealias KdlParseError = FormatCore.ParseError<KdlErrorKind>;`) with its own
/// error-kind enum.
///
/// The error owns nothing and needs no cleanup, so it can be dropped freely (including by `Try!`). Its
/// text views per-thread buffers, one set per error-kind type: it stays valid until the next error of
/// the same format is created on the same thread. Copy it to keep it longer (`Diagnostic<TKind>`).
public struct ParseError<TKind> where TKind : struct
{
	static LazyTLS<String> sMessageBuffer = new .() ~ delete _;
	static LazyTLS<String> sSourceBuffer = new .() ~ delete _;
	static LazyTLS<String> sPathBuffer = new .() ~ delete _;

	/// @brief The category of error.
	public TKind mKind;
	/// @brief Human-readable description. Valid until the next error on this thread.
	public StringView mMessage;
	/// @brief Name of the input the position refers to; empty if unnamed. Valid until the next error
	/// on this thread.
	public StringView mSource;
	/// @brief Where in a typed object the error is (a JSON Pointer, a dotted key path; the format
	/// chooses), built from the inside out by PrependPath; empty for none. Valid until the next error on
	/// this thread.
	public StringView mPath;
	/// @brief 1-based line (0 when there is no position).
	public int32 mLine;
	/// @brief 1-based column, in code points.
	public int32 mColumn;
	/// @brief Byte offset into the input.
	public int64 mOffset;
	/// @brief Length of the erroneous span in bytes.
	public int32 mLength;

	/// @brief Creates an error at the given location.
	/// @param kind The category of error.
	/// @param message Human-readable description (copied).
	/// @param line 1-based line number (0: no position).
	/// @param column 1-based column number, in code points.
	/// @param offset Byte offset into the input.
	/// @param length Length of the erroneous span in bytes.
	public this(TKind kind, StringView message, int line, int column, int64 offset, int length = 1)
	{
		mKind = kind;
		mLine = (int32)line;
		mColumn = (int32)column;
		mOffset = offset;
		mLength = (int32)length;
		mMessage = PerThreadText.Store(sMessageBuffer.Value, message);
		mSource = default;
		mPath = default;
	}

	/// @brief An error at byte `offset` of `input`, with the line and column computed from it under the
	/// format's newline rules.
	/// @param kind The category of error.
	/// @param message Human-readable description (copied).
	/// @param input The whole input.
	/// @param offset Byte offset into it.
	/// @param length Length of the erroneous span in bytes.
	/// @return The error.
	internal static Self At<TText>(TKind kind, StringView message, StringView input, int offset, int length = 1) where TText : ITextPolicy
	{
		Utf8.LineAndColumn<TText>(input, offset, let line, let column);
		return Self(kind, message, line, column, offset, length);
	}

	/// @brief Prepends `segment` to mPath verbatim (`/name` for a JSON Pointer, the format escapes it):
	/// typed binding builds the path as the error leaves each level.
	/// @param segment The text to prepend.
	public void PrependPath(StringView segment) mut
	{
		let buffer = sPathBuffer.Value;
		if (mPath.IsEmpty)
			buffer.Set(segment);
		else if (mPath.Ptr == buffer.Ptr && mPath.Length == buffer.Length)
			buffer.Insert(0, segment);
		else
		{
			// A path from elsewhere (a Diagnostic's): copied after the segment
			let rest = scope String(mPath);
			buffer.Set(segment);
			buffer.Append(rest);
		}
		mPath = buffer;
	}

	/// @brief Set the source name the position refers to. Stored like the message: valid until the next
	/// error on this thread.
	/// @param source The source name, e.g. a file path.
	public void SetSource(StringView source) mut
	{
		mSource = PerThreadText.Store(sSourceBuffer.Value, source);
	}

	/// @brief Copy the message, source name and path into this thread's error buffers, so the error no
	/// longer depends on where they were (a Diagnostic, a document's collected errors). Afterwards it is
	/// like any other: valid until the next error on this thread.
	public void Detach() mut
	{
		mMessage = PerThreadText.Store(sMessageBuffer.Value, mMessage);
		let source = mSource;
		mSource = default;
		if (!source.IsEmpty)
			mSource = PerThreadText.Store(sSourceBuffer.Value, source);
		let path = mPath;
		mPath = default;
		if (!path.IsEmpty)
			mPath = PerThreadText.Store(sPathBuffer.Value, path);
	}

	/// @brief Formats the error as `source:line:column: path: message`, dropping the parts that are
	/// unknown (no source name, no position: line 0, no path).
	/// @param strBuffer The string to append to.
	public override void ToString(String strBuffer)
	{
		if (!mSource.IsEmpty)
		{
			strBuffer.Append(mSource);
			strBuffer.Append(':');
		}
		if (mLine > 0)
			strBuffer.AppendF("{}:{}:", mLine, mColumn);
		if (!mSource.IsEmpty || mLine > 0)
			strBuffer.Append(' ');
		if (!mPath.IsEmpty)
		{
			strBuffer.Append(mPath);
			strBuffer.Append(": ");
		}
		strBuffer.Append(mMessage);
	}
}

/// @brief An error that owns its text, for keeping it: a list of diagnostics, errors from several
/// readers, documents or threads (a ParseError's text views per-thread buffers that the next error on
/// the thread replaces). Delete it when done. Each format names its specialization
/// (`public typealias XmlDiagnostic = FormatCore.Diagnostic<XmlErrorKind>;`).
public class Diagnostic<TKind> where TKind : struct
{
	/// @brief The category of error.
	public TKind mKind;
	/// @brief Human-readable description.
	public String mMessage ~ delete _;
	/// @brief Name of the input the position refers to; empty if unnamed.
	public String mSource ~ delete _;
	/// @brief Where in a typed object the error is; empty for none.
	public String mPath ~ delete _;
	/// @brief 1-based line (0 when there is no position).
	public int32 mLine;
	/// @brief 1-based column, in code points.
	public int32 mColumn;
	/// @brief Byte offset into the input.
	public int64 mOffset;
	/// @brief Length of the erroneous span in bytes.
	public int32 mLength;

	/// @brief Copy an error.
	/// @param error The error (its text is copied, so it may be the last one of its thread).
	public this(ParseError<TKind> error)
	{
		mKind = error.mKind;
		mMessage = new String(error.mMessage);
		mSource = new String(error.mSource);
		mPath = new String(error.mPath);
		mLine = error.mLine;
		mColumn = error.mColumn;
		mOffset = error.mOffset;
		mLength = error.mLength;
	}

	/// @brief The diagnostic as a ParseError whose text views this object (valid while it lives;
	/// `Detach` it to outlive it).
	public ParseError<TKind> Error
	{
		get
		{
			ParseError<TKind> error = default;
			error.mKind = mKind;
			error.mMessage = mMessage;
			error.mSource = mSource;
			error.mPath = mPath;
			error.mLine = mLine;
			error.mColumn = mColumn;
			error.mOffset = mOffset;
			error.mLength = mLength;
			return error;
		}
	}

	/// @brief Formats the diagnostic as ParseError.ToString does (`source:line:column: path: message`).
	/// @param strBuffer The string to append to.
	public override void ToString(String strBuffer)
	{
		Error.ToString(strBuffer);
	}
}
