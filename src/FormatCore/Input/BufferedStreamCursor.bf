using System;
using System.Collections;
using System.IO;
using internal FormatCore;

namespace FormatCore;

/// What a stream read owns (a cursor is a struct): the buffer and the input's error, kept in parts with
/// its own copy of the message (an InputError's message lives in a per-thread buffer that the next
/// error overwrites). The reader keeps one and reuses it across reads.
internal class InputState
{
	public List<uint8> mBuffer ~ delete _;
	public bool mHasError;
	public InputErrorKind mErrorKind;
	public String mErrorMessage ~ delete _;
	public int mErrorLine;
	public int mErrorColumn;
	public int mErrorOffset;
	public int mErrorLength;

	public this()
	{
		mBuffer = new .();
		mErrorMessage = new .();
	}

	/// @brief The error as an InputError (its message copied to the per-thread buffer).
	/// @return The error.
	public InputError MakeError()
	{
		return InputError(mErrorKind, mErrorMessage, mErrorLine, mErrorColumn, mErrorOffset, mErrorLength);
	}
}

/// A stream read through a buffer (KdlBeef's KdlBufferedStreamCursor and JsonBeef's
/// JsonBufferedStreamCursor, merged): the window is the buffered part of the input from the reader's
/// current construct on. A refill drops the bytes before that construct and moves the rest to the
/// front; a construct longer than the buffer doubles it, bounded by MaxTokenBytes, which is a hard limit
/// on the construct plus the lookahead the reader asks for. When the text policy validates up front,
/// bytes are validated as they arrive and the window ends at the last complete, valid code point, so
/// the reader never sees bytes that are not (and a document that fits the first buffer reports the
/// same first error as from memory); otherwise the window is every byte read, up to an input error.
/// Lines are counted only up to the bytes dropped and up to what is located (LineCounter).
internal struct BufferedStreamCursor<TText> : IInputCursor where TText : ITextPolicy
{
	Stream mStream;
	InputState mState;
	InputSettings mSettings;
	/// Absolute offset of the buffer's first byte.
	int mBase;
	/// Bytes in the buffer, and how many of them the window shows.
	int mRaw;
	int mValid;
	/// The stream is exhausted, or failed (mState.mHasError).
	bool mDone;
	int mBytesRead;
	/// The size of the buffer (kept beside mBuffer.Count, whose setter is not inlined).
	int mCapacity;
	/// Lines counted up to the bytes dropped from the buffer: nothing before it can be located.
	LineCounter<TText> mLines;
	/// Lines counted forward for Locate; a request behind it counts from mLines instead.
	LineCounter<TText> mLocated;

	/// @brief A cursor over `stream`.
	/// @param stream The stream (borrowed for the read).
	/// @param state The buffer and error storage (reset here).
	/// @param settings The cursor settings.
	public this(Stream stream, InputState state, InputSettings settings)
	{
		mStream = stream;
		mState = state;
		mSettings = settings;
		mBase = 0;
		mRaw = 0;
		mValid = 0;
		mDone = false;
		mBytesRead = 0;
		mLines = .(0);
		mLocated = .(0);
		state.mHasError = false;
		mCapacity = settings.StreamBufferSize;
		state.mBuffer.Count = mCapacity;
	}

	[Inline]
	char8* Buffer => (char8*)mState.mBuffer.Ptr;

	public Result<int, InputError> Begin(ref char8* data, ref int windowStart, ref int end) mut
	{
		// Enough to see a BOM or a UTF-16/32 pattern (or the whole input, if it is shorter)
		while (mRaw < 4 && !mDone)
			ReadMore();
		data = Buffer;
		windowStart = 0;
		end = 0;
		if (mState.mHasError)
			return .Err(mState.MakeError());
		int start = 0;
		switch (InputStart.Check(Buffer, mRaw, mSettings))
		{
		case .Ok(let offset):
			start = offset;
		case .Err(let error):
			SetError(error.mKind, error.mMessage, 0, error.mLength);
			return .Err(mState.MakeError());
		}
		mValid = start;
		mLines = .(start);
		mLocated = .(start);
		// The first buffer, validated in full: a document that fits it reports the same first error as
		// from memory
		while (mRaw < mCapacity && !mDone)
			ReadMore();
		Validate();
		SetWindow(ref data, ref windowStart, ref end, start);
		if (mState.mHasError)
			return .Err(mState.MakeError());
		return start;
	}

	public bool Fill(ref char8* data, ref int windowStart, ref int end, int keep, int pos, int count) mut
	{
		int oldEnd = end;
		int from = Math.Min(keep, pos);
		int maxToken = mSettings.mMaxTokenBytes;
		// The reader would hold the construct from `from` through what it looks at at once: that is what
		// MaxTokenBytes bounds, whatever the buffer's size. Only when those bytes exist (in the buffer,
		// or maybe still in the stream): at the end of the input a construct that fills the limit
		// exactly is within it.
		if (maxToken > 0 && pos + count - from > maxToken && (pos + count <= mBase + mValid || !mDone))
		{
			SetError(.ResourceLimitExceeded, scope $"A token is longer than MaxTokenBytes ({maxToken})", from + maxToken);
			SetWindow(ref data, ref windowStart, ref end, from);
			return false;
		}
		while (mBase + mValid < pos + count && !mDone)
		{
			// Drop what the reader is done with, counting its lines first; never just after a CR (an LF
			// may follow, and the two halves of a CRLF would count as two newlines)
			int drop = from - mBase;
			if (drop > 0 && Buffer[drop - 1] == '\r')
				drop--;
			if (drop > 0)
			{
				char8* text = Buffer - mBase;
				int dropTo = mBase + drop;
				if (mLocated.mPos <= dropTo)
				{
					mLocated.AdvanceLines(text, dropTo, mBase + mRaw);
					mLocated.Column(text, dropTo);
					mLines = mLocated;
				}
				else
				{
					mLines.AdvanceLines(text, Math.Max(dropTo, mLines.mPos), mBase + mRaw);
					mLines.Column(text, dropTo);
					if (mLocated.mLineStart < dropTo)
						mLocated.Column(text, dropTo);
				}
				Internal.MemMove(Buffer, Buffer + drop, mRaw - drop);
				mBase += drop;
				mRaw -= drop;
				mValid -= drop;
			}
			if (mRaw == mCapacity)
			{
				// One construct fills the buffer: grow it, never past MaxTokenBytes. A full buffer of that
				// size still short of `pos + count` means the construct is longer than the limit.
				if (maxToken > 0 && mRaw >= maxToken)
				{
					SetError(.ResourceLimitExceeded, scope $"A token is longer than MaxTokenBytes ({maxToken})", mBase + mRaw);
					break;
				}
				int grown = mCapacity * 2;
				if (maxToken > 0)
					grown = Math.Min(grown, maxToken);
				mCapacity = grown;
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
		data = Buffer - mBase;
		windowStart = mBase;
		end = mBase + mValid;
		int maxToken = mSettings.mMaxTokenBytes;
		if (maxToken > 0 && from + maxToken < end)
			end = Math.Max(from + maxToken, mBase);
	}

	/// Reads once into the free part of the buffer.
	void ReadMore() mut
	{
		// A full buffer reads nothing (a zero-length read would look like the end of the stream)
		if (mDone || mRaw == mCapacity)
			return;
		switch (mStream.TryRead(.(mState.mBuffer.Ptr + mRaw, mCapacity - mRaw)))
		{
		case .Ok(let read):
			if (read <= 0)
			{
				mDone = true;
				return;
			}
			mRaw += read;
			mBytesRead += read;
			int maxInput = mSettings.mMaxInputBytes;
			if (maxInput > 0 && mBytesRead > maxInput)
				SetError(.ResourceLimitExceeded, scope $"The input exceeds MaxInputBytes ({maxInput})", maxInput, 0);
		case .Err:
			SetError(.IoError, "Reading the input failed", mBase + mRaw, 0);
		}
	}

	/// Extends the window over the newly read bytes: when the policy validates up front, up to the last
	/// complete code point (all of them at the end of the input), stopping the stream at the first
	/// invalid one; always up to an input error's offset.
	void Validate() mut
	{
		char8* text = Buffer - mBase;
		int from = mBase + mValid;
		int to = mBase + mRaw;
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
		int target = Math.Min(offset, mBase + mRaw);
		char8* text = Buffer - mBase;
		if (mLocated.CanReach(target))
		{
			mLocated.Locate(text, target, mBase + mRaw, out line, out column);
			return true;
		}
		// Behind the forward count (an error at an earlier offset): count from the dropped bytes
		var lines = mLines;
		lines.Locate(text, target, mBase + mRaw, out line, out column);
		return true;
	}
}
