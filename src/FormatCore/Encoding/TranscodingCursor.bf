using System;
using System.Collections;
using System.IO;
using internal FormatCore;

namespace FormatCore;

/// An in-memory input in any encoding (XmlBeef's XmlByteCursor): detected and transcoded to UTF-8 at
/// Begin (Transcoding.Prepare), then validated up front when the text policy says so; the window is the
/// whole UTF-8 text and Fill never has more. Offsets are UTF-8 offsets into that text.
internal struct TranscodingByteCursor<TText, TDetect> : IInputCursor where TText : ITextPolicy where TDetect : IEncodingDetector
{
	StringView mInput;
	StringView mText;
	/// Receives the UTF-8 text of input in another encoding (owned by the reader), and the declared name.
	TranscodingState mState;
	InputSettings mSettings;
	TranscodeSettings mTranscode;
	LineCounter<TText> mLines;
	EncodingDetection mDetection;

	/// @brief A cursor over `input`.
	/// @param input The input's bytes (borrowed for the read).
	/// @param state The transcoding buffers (reused across reads).
	/// @param settings The cursor settings.
	/// @param transcode The converter and the fallback.
	public this(StringView input, TranscodingState state, InputSettings settings, TranscodeSettings transcode)
	{
		mInput = input;
		mText = input;
		mState = state;
		mSettings = settings;
		mTranscode = transcode;
		mLines = .(0);
		mDetection = .();
	}

	/// @brief What detection found (after Begin); mEncoding is the encoding the input was read in.
	public EncodingDetection Detection => mDetection;

	/// @brief The encoding the input was read in (after Begin).
	public TextEncoding Encoding => mDetection.mEncoding;

	/// @brief The UTF-8 text the reader's offsets index (after Begin): the input, or its transcoding.
	public StringView Text => mText;

	public Result<int, InputError> Begin(ref char8* data, ref int windowStart, ref int end) mut
	{
		data = mInput.Ptr;
		windowStart = 0;
		end = 0;
		if (mSettings.mMaxInputBytes > 0 && mInput.Length > mSettings.mMaxInputBytes)
			return .Err(InputError(.ResourceLimitExceeded, scope $"The input ({mInput.Length} bytes) exceeds MaxInputBytes ({mSettings.mMaxInputBytes})", 1, 1, 0, 0));
		int start = 0;
		if (Transcoding.Prepare<TText, TDetect>(mInput, mState.mWhole, mSettings, mTranscode, mState.mDeclared, mState.mScratch,
			out mText, out start, out mDetection) case .Err(let error))
			return .Err(error);
		data = mText.Ptr;
		end = mText.Length;
		mLines = .(start);
		if (TText.ValidatesUpFront)
		{
			let message = scope String();
			int bad = Utf8.FindInvalid<TText>(mText.Ptr, start, mText.Length, message, let kind, let length);
			if (bad >= 0)
			{
				Locate(bad, let line, let column);
				return .Err(InputError(kind, message, line, column, bad, length));
			}
		}
		return start;
	}

	[Inline]
	public bool Fill(ref char8* data, ref int windowStart, ref int end, int keep, int pos, int count) mut
	{
		return false;
	}

	[Inline]
	public bool TryGetInputError(out InputError error)
	{
		error = default;
		return false;
	}

	public bool HasInputError
	{
		[Inline]
		get => false;
	}

	public bool IsWhole
	{
		[Inline]
		get => true;
	}

	[Inline]
	public bool TakeStarved() mut => false;

	public bool Locate(int offset, out int line, out int column) mut
	{
		int target = Math.Min(offset, mText.Length);
		if (!mLines.CanReach(target))
		{
			Utf8.LineAndColumn<TText>(mText, target, out line, out column);
			return true;
		}
		mLines.Locate(mText.Ptr, target, mText.Length, out line, out column);
		return true;
	}
}

/// What a transcoding read owns (a cursor is a struct): InputState's UTF-8 window buffer and error, the
/// raw bytes read but not decoded yet, the whole input's transcoding (memory input, or a stream read
/// whole for a converter or the fallback), the declared encoding name, and the detector's scratch.
internal class TranscodingState : InputState
{
	public List<uint8> mRaw ~ delete _;
	public String mWhole ~ delete _;
	public String mDeclared ~ delete _;
	public String mScratch ~ delete _;

	public this()
	{
		mRaw = new .();
		mWhole = new .();
		mDeclared = new .();
		mScratch = new .();
	}
}

/// A stream in any encoding read through a buffer (XmlBeef's XmlBufferedStreamCursor, with the
/// detection a generic hook): the window is the decoded (UTF-8) part of the input from the reader's
/// current construct on. The encoding is detected from the stream's first `TDetect.PrefixBytes` (more
/// while the detector says the prefix is incomplete); the rest is decoded as it arrives (a code unit cut
/// off at a read's end waits for the next), so offsets are UTF-8 offsets exactly as for the same input
/// in memory. A converter or the Windows-1252 fallback needs the whole input at once: then the stream is
/// read to its end first.
///
/// A refill drops the bytes before the reader's construct and moves the rest to the front; a construct
/// longer than the buffer doubles it (bounded by MaxTokenBytes). When the text policy validates up
/// front, bytes are validated as they arrive and the window ends at the last complete, valid code point.
internal struct TranscodingStreamCursor<TText, TDetect> : IInputCursor where TText : ITextPolicy where TDetect : IEncodingDetector
{
	Stream mStream;
	TranscodingState mState;
	InputSettings mSettings;
	TranscodeSettings mTranscode;
	Decoder mDecoder;
	EncodingDetection mDetection;
	/// Absolute (UTF-8) offset of the buffer's first byte.
	int mBase;
	/// UTF-8 bytes in the buffer, and how many of them the window shows.
	int mFilled;
	int mValid;
	/// The first undecoded byte in mState.mRaw.
	int mRawStart;
	/// The stream is exhausted (raw bytes may still wait to be decoded).
	bool mEof;
	/// Nothing more will be decoded: the input is all in the buffer, or failed (mState.mHasError).
	bool mDone;
	int mBytesRead;
	/// Lines counted up to the bytes dropped from the buffer: nothing before it can be located.
	LineCounter<TText> mLines;
	/// Lines counted forward for Locate; a request behind it counts from mLines instead.
	LineCounter<TText> mLocated;

	/// @brief A cursor over `stream`.
	/// @param stream The stream (borrowed for the read).
	/// @param state The buffers and error storage (reset here).
	/// @param settings The cursor settings.
	/// @param transcode The converter and the fallback.
	[Inline]
	public this(Stream stream, TranscodingState state, InputSettings settings, TranscodeSettings transcode)
	{
		mStream = stream;
		mState = state;
		mSettings = settings;
		mTranscode = transcode;
		mDecoder = Decoder(.Utf8);
		mDetection = .();
		mBase = 0;
		mFilled = 0;
		mValid = 0;
		mRawStart = 0;
		mEof = false;
		mDone = false;
		mBytesRead = 0;
		mLines = .(0);
		mLocated = .(0);
		state.mHasError = false;
		state.mRaw.Clear();
		state.mDeclared.Clear();
		state.mBuffer.Count = settings.StreamBufferSize;
	}

	[Inline]
	uint8* Buffer => mState.mBuffer.Ptr;

	/// @brief What detection found (after Begin); mEncoding is the encoding the input was read in.
	public EncodingDetection Detection => mDetection;

	/// @brief The encoding the input was read in (after Begin).
	public TextEncoding Encoding => mDetection.mEncoding;

	public Result<int, InputError> Begin(ref char8* data, ref int windowStart, ref int end) mut
	{
		data = (char8*)Buffer;
		windowStart = 0;
		end = 0;
		// Enough to detect the encoding (the whole input, if it is shorter)
		int prefixBytes = TDetect.PrefixBytes;
		while (mState.mRaw.Count < prefixBytes && !mEof)
		{
			if (!ReadRaw(prefixBytes - mState.mRaw.Count))
				break;
		}
		if (mState.mHasError)
			return .Err(mState.MakeError());
		while (true)
		{
			StringView prefix = .((char8*)mState.mRaw.Ptr, mState.mRaw.Count);
			switch (TDetect.Detect(prefix, mState.mDeclared, mState.mScratch))
			{
			case .Ok(let found):
				mDetection = found;
			case .Err(let error):
				return .Err(Fail(error));
			}
			// More of the input while the detector needs it, as memory input does
			if (!mDetection.mIncomplete || mEof)
				break;
			if (Transcoding.CheckPrefixLength<TDetect>(mState.mRaw.Count, mSettings) case .Err(let tooLong))
				return .Err(Fail(tooLong));
			int target = mState.mRaw.Count * 2;
			while (mState.mRaw.Count < target && !mEof)
			{
				if (!ReadRaw(target - mState.mRaw.Count))
					break;
			}
			if (mState.mHasError)
				return .Err(mState.MakeError());
		}
		int start = mDetection.mUtf8Bom ? 3 : 0;
		if (mDetection.mUtf8Bom && mSettings.mBom == .Reject)
			return .Err(Fail(InputError(.ByteOrderMark, "A byte order mark (U+FEFF) is not allowed", 1, 1, 0, 3)));
		if (mDetection.mConvert || (mDetection.mUndeclared && mTranscode.mFallback != .None))
		{
			// The converter and the fallback take the whole input
			if (ReadWhole(ref start) case .Err(let error))
				return .Err(Fail(error));
		}
		else
		{
			mDecoder = Decoder(mDetection.mEncoding);
			mRawStart = mDetection.mSkip;
			// The whole input came with the detection prefix: check it all now, as for memory, so a small
			// input reports the same first error from a stream (read on through the buffer all the same)
			if (mEof && CheckWhole(start) case .Err(let error))
				return .Err(Fail(error));
			// The first buffer, validated: an input that fits it reports the same first error as from memory
			while (mFilled < mState.mBuffer.Count && !mDone)
			{
				if (!ReadMore())
					break;
			}
		}
		mValid = start;
		mLines = .(start);
		mLocated = .(start);
		Validate();
		SetWindow(ref data, ref windowStart, ref end, start);
		if (mState.mHasError)
			return .Err(mState.MakeError());
		return start;
	}

	/// Records a Begin error as the input's error (so TryGetInputError has it too) and returns it.
	InputError Fail(InputError error) mut
	{
		mDone = true;
		mEof = true;
		if (!mState.mHasError)
		{
			mState.mErrorKind = error.mKind;
			mState.mErrorMessage.Set(error.mMessage);
			mState.mErrorLine = error.mLine;
			mState.mErrorColumn = error.mColumn;
			mState.mErrorOffset = (int)error.mOffset;
			mState.mErrorLength = error.mLength;
			mState.mHasError = true;
		}
		return mState.MakeError();
	}

	/// Decodes and validates the whole input (all in mState.mRaw) into scratch space, failing as the
	/// in-memory path would: the first encoding or character error, located in the decoded text.
	Result<void, InputError> CheckWhole(int start) mut
	{
		let text = mState.mWhole;
		int length = mState.mRaw.Count - mRawStart;
		int capacity = length * mDecoder.MaxExpansion + 8;
		text.Clear();
		uint8* dst = (uint8*)text.PrepareBuffer(capacity);
		var decoder = mDecoder;
		bool ok = decoder.Decode(mState.mRaw.Ptr + mRawStart, length, true, dst, capacity, let consumed, let produced, let error);
		text.Length = produced;
		if (!ok)
			return .Err(Transcoding.DecodeError<TText>(error, mDetection.mEncoding, mState.mDeclared, mState.mRaw[mRawStart + consumed], text, produced));
		if (TText.ValidatesUpFront)
		{
			let message = scope String();
			int bad = Utf8.FindInvalid<TText>(text.Ptr, start, text.Length, message, let kind, let badLength);
			if (bad >= 0)
			{
				Utf8.LineAndColumn<TText>(text, bad, let line, let column);
				return .Err(InputError(kind, message, line, column, bad, badLength));
			}
		}
		return .Ok;
	}

	/// Reads the rest of the stream and transcodes it all at once (Transcoding.Prepare), for the
	/// converter or the fallback.
	Result<void, InputError> ReadWhole(ref int start) mut
	{
		while (!mEof)
		{
			if (!ReadRaw(64 * 1024))
				break;
		}
		if (mState.mHasError)
			return .Err(mState.MakeError());
		StringView input = .((char8*)mState.mRaw.Ptr, mState.mRaw.Count);
		// (The size limit was counted as the stream was read)
		var settings = mSettings;
		settings.mMaxInputBytes = 0;
		Try!(Transcoding.Prepare<TText, TDetect>(input, mState.mWhole, settings, mTranscode, mState.mDeclared, mState.mScratch,
			let text, out start, out mDetection));
		mState.mBuffer.Count = Math.Max(text.Length, mState.mBuffer.Count);
		Internal.MemCpy(Buffer, text.Ptr, text.Length);
		mFilled = text.Length;
		mDone = true;
		mEof = true;
		// The token limit still holds: SetWindow shows no more than MaxTokenBytes from the current
		// construct, so a longer one comes to Fill's check as from any stream
		return .Ok;
	}

	/// Reads once from the stream into mState.mRaw (at most `want` bytes). @return Whether anything came.
	bool ReadRaw(int want) mut
	{
		if (mEof)
			return false;
		// Drop what was decoded
		if (mRawStart > 0)
		{
			int left = mState.mRaw.Count - mRawStart;
			Internal.MemMove(mState.mRaw.Ptr, mState.mRaw.Ptr + mRawStart, left);
			mState.mRaw.Count = left;
			mRawStart = 0;
		}
		int count = mState.mRaw.Count;
		int chunk = Math.Max(want, 16);
		mState.mRaw.Count = count + chunk;
		switch (mStream.TryRead(.(mState.mRaw.Ptr + count, chunk)))
		{
		case .Ok(let read):
			mState.mRaw.Count = count + Math.Max(read, 0);
			if (read <= 0)
			{
				mEof = true;
				return false;
			}
			mBytesRead += read;
			int maxInput = mSettings.mMaxInputBytes;
			if (maxInput > 0 && mBytesRead > maxInput)
			{
				SetError(.ResourceLimitExceeded, scope $"The input exceeds MaxInputBytes ({maxInput})", mBase + mFilled, 0);
				mEof = true;
				return false;
			}
			return true;
		case .Err:
			mState.mRaw.Count = count;
			SetError(.IoError, "Reading the input failed", mBase + mFilled, 0);
			mEof = true;
			return false;
		}
	}

	/// Decodes more input into the buffer's free space, reading the stream as needed.
	/// @return Whether anything was added (false: the buffer is full, or the input ended or failed).
	bool ReadMore() mut
	{
		while (!mDone)
		{
			int free = mState.mBuffer.Count - mFilled;
			if (free < 4 && (mDecoder.Encoding != .Utf8 || free == 0))
				return false;
			int pending = mState.mRaw.Count - mRawStart;
			if (pending > 0)
			{
				bool ok = mDecoder.Decode(mState.mRaw.Ptr + mRawStart, pending, mEof, Buffer + mFilled, free, let consumed, let produced, let error);
				mRawStart += consumed;
				mFilled += produced;
				if (!ok)
				{
					let message = scope String();
					Decoder.AppendError(message, error, mDecoder.Encoding, mState.mDeclared, mState.mRaw[mRawStart]);
					SetError(.InvalidEncoding, message, mBase + mFilled);
					return produced > 0;
				}
				if (produced > 0)
					return true;
				if (mEof)
				{
					mDone = true;
					return false;
				}
				// A code unit cut off at the end of what was read: read on
			}
			else if (mEof)
			{
				mDone = true;
				return false;
			}
			ReadRaw(Math.Max(free, 4096));
		}
		return false;
	}

	public bool Fill(ref char8* data, ref int windowStart, ref int end, int keep, int pos, int count) mut
	{
		int oldEnd = end;
		int from = Math.Min(keep, pos);
		int maxToken = mSettings.mMaxTokenBytes;
		// The construct from `from` through what the reader looks at is what MaxTokenBytes bounds, when
		// those bytes exist (in the buffer, or maybe still in the stream)
		if (maxToken > 0 && pos + count - from > maxToken && (pos + count <= mBase + mValid || !mDone))
		{
			SetError(.ResourceLimitExceeded, scope $"A token is longer than MaxTokenBytes ({maxToken})", from + maxToken);
			SetWindow(ref data, ref windowStart, ref end, from);
			return false;
		}
		while (mBase + mValid < pos + count)
		{
			// Nothing more will come (the end, or an error: the window stops at the error)
			if (mDone)
				break;
			// Drop what the reader is done with, counting its lines first; never just after a CR (an LF
			// may follow, and the two halves of a CRLF would count as two newlines)
			int drop = from - mBase;
			if (drop > 0 && Buffer[drop - 1] == (uint8)'\r')
				drop--;
			if (drop > 0)
			{
				char8* text = (char8*)Buffer - mBase;
				int dropTo = mBase + drop;
				if (mLocated.mPos <= dropTo)
				{
					mLocated.AdvanceLines(text, dropTo, mBase + mFilled);
					mLocated.Column(text, dropTo);
					mLines = mLocated;
				}
				else
				{
					mLines.AdvanceLines(text, Math.Max(dropTo, mLines.mPos), mBase + mFilled);
					mLines.Column(text, dropTo);
					if (mLocated.mLineStart < dropTo)
						mLocated.Column(text, dropTo);
				}
				Internal.MemMove(Buffer, Buffer + drop, mFilled - drop);
				mBase += drop;
				mFilled -= drop;
				mValid -= drop;
			}
			if (mState.mBuffer.Count - mFilled < 4)
			{
				// One construct fills the buffer: grow it, never past MaxTokenBytes (and room for a code point)
				if (maxToken > 0 && mFilled >= maxToken)
				{
					SetError(.ResourceLimitExceeded, scope $"A token is longer than MaxTokenBytes ({maxToken})", mBase + mFilled);
					break;
				}
				int grown = mState.mBuffer.Count * 2;
				if (maxToken > 0)
					grown = Math.Min(grown, maxToken + 4);
				mState.mBuffer.Count = grown;
			}
			ReadMore();
			Validate();
		}
		SetWindow(ref data, ref windowStart, ref end, from);
		return end > oldEnd;
	}

	/// The window: the validated bytes, but with MaxTokenBytes no more than that from `from` (the
	/// construct being read), so a longer construct always comes to Fill's check.
	void SetWindow(ref char8* data, ref int windowStart, ref int end, int from)
	{
		data = (char8*)Buffer - mBase;
		windowStart = mBase;
		end = mBase + mValid;
		int maxToken = mSettings.mMaxTokenBytes;
		if (maxToken > 0 && from + maxToken < end)
			end = Math.Max(from + maxToken, mBase);
	}

	/// Extends the window over the newly decoded bytes: when the policy validates up front, up to the
	/// last complete code point (all of them at the end of the input), stopping at the first invalid
	/// one; always up to an input error's offset.
	void Validate() mut
	{
		char8* text = (char8*)Buffer - mBase;
		int from = mBase + mValid;
		int to = mBase + mFilled;
		if (TText.ValidatesUpFront && !mDone)
			to = Utf8.CompleteSequencesEnd(text, from, to);
		if (mState.mHasError)
			to = Math.Max(Math.Min(to, mState.mErrorOffset), from);
		if (TText.ValidatesUpFront)
		{
			let message = scope String();
			int bad = Utf8.FindInvalid<TText>(text, from, to, message, let kind, let length);
			if (bad >= 0)
			{
				mValid = bad - mBase;
				SetError(kind, message, bad, length);
				return;
			}
		}
		mValid = to - mBase;
	}

	/// Records the input's first error and stops reading.
	void SetError(InputErrorKind kind, StringView message, int offset, int length = 1) mut
	{
		mDone = true;
		if (mState.mHasError)
			return;
		Locate(offset, out mState.mErrorLine, out mState.mErrorColumn);
		mState.mErrorKind = kind;
		mState.mErrorMessage.Set(message);
		mState.mErrorOffset = offset;
		mState.mErrorLength = length;
		mState.mHasError = true;
	}

	public bool TryGetInputError(out InputError error)
	{
		error = mState.mHasError ? mState.MakeError() : default;
		return mState.mHasError;
	}

	public bool HasInputError => mState.mHasError;

	public bool IsWhole
	{
		[Inline]
		get => false;
	}

	[Inline]
	public bool TakeStarved() mut => false;

	public bool Locate(int offset, out int line, out int column) mut
	{
		line = 0;
		column = 0;
		if (offset < mLines.mPos)
			return false;
		int target = Math.Min(offset, mBase + mFilled);
		char8* text = (char8*)Buffer - mBase;
		if (mLocated.CanReach(target))
		{
			mLocated.Locate(text, target, mBase + mFilled, out line, out column);
			return true;
		}
		// Behind the forward count (an error at an earlier offset): count from the dropped bytes
		var lines = mLines;
		lines.Locate(text, target, mBase + mFilled, out line, out column);
		return true;
	}
}
