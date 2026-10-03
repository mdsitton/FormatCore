using System;
using internal FormatCore;

namespace FormatCore;

/// Where a reader core's bytes come from (KdlBeef's IKdlCursor, XmlBeef's IXmlCursor and JsonBeef's
/// IJsonCursor, merged). The reader reads a window of the input through a pointer `data` indexed by
/// absolute offsets (`data[offset]`, valid for `windowStart <= offset < end`), so offsets it keeps stay
/// valid when a stream moves or grows its buffer; only `data`, `windowStart` and `end` change.
/// Cursors are structs and readers are generic over them (`ReaderCore<TCursor> where TCursor :
/// IInputCursor`), so no call here is virtual and a memory cursor's Fill folds to `false`.
internal interface IInputCursor
{
	/// Checks the start of the input (size, wide encodings, the BOM), validates what the text policy
	/// validates up front (all of a memory input; a stream's first buffer) and sets up the window.
	/// @return The offset of the first content byte (after a BOM), or the input's error.
	Result<int, InputError> Begin(ref char8* data, ref int windowStart, ref int end) mut;

	/// Makes the input up to `pos + count` available if there is that much, keeping every byte from
	/// `min(keep, pos)` on in the window (the reader's current construct). The window may move.
	/// @return Whether `end` grew.
	bool Fill(ref char8* data, ref int windowStart, ref int end, int keep, int pos, int count) mut;

	/// An error of the input itself (I/O, encoding, size) that stopped Fill. The reader reports it in
	/// place of its own once it has run into the end of what Fill delivered. Making the error writes
	/// the per-thread message buffer: to only ask whether there is one, use HasInputError.
	bool TryGetInputError(out InputError error);

	/// Whether the input has failed (TryGetInputError would make an error), without making one.
	bool HasInputError { get; }

	/// The 1-based line and column (in code points) of `offset`: always for in-memory input; for a
	/// stream only from the earliest offset it still holds (false before that).
	bool Locate(int offset, out int line, out int column) mut;

	/// Whether the whole input is in the window from the start (memory). When false, Locate only works
	/// forward, so positions an error may need later must be located when they are read.
	bool IsWhole { get; }

	/// Push input: whether Begin or Fill ran out of what has been fed so far since the last call;
	/// clears it. Memory and streams never run out that way (`[Inline]` false).
	bool TakeStarved() mut;
}

/// Window helpers every reader core needs after a Fill moved the window.
internal static class Window
{
	/// @brief Moves a view of the old window (`[low, high)` in the old buffer) to the same offsets in
	/// the new one; leaves any other view alone.
	/// @param view The view.
	/// @param low The old window's first byte.
	/// @param high One past the old window's last byte.
	/// @param oldData The old `data` pointer.
	/// @param newData The new `data` pointer.
	[Inline]
	public static void Rebase(ref StringView view, char8* low, char8* high, char8* oldData, char8* newData)
	{
		if (view.Ptr >= low && view.Ptr < high)
			view = .(newData + (view.Ptr - oldData), view.Length);
	}
}

/// An in-memory input: the window is the whole input, validated up front when the text policy says
/// so; Fill never has more.
internal struct ByteCursor<TText> : IInputCursor where TText : ITextPolicy
{
	StringView mInput;
	InputSettings mSettings;
	LineCounter<TText> mLines;

	/// @brief A cursor over `input`.
	/// @param input The input (borrowed for the read).
	/// @param settings The cursor settings.
	public this(StringView input, InputSettings settings)
	{
		mInput = input;
		mSettings = settings;
		mLines = .(0);
	}

	public Result<int, InputError> Begin(ref char8* data, ref int windowStart, ref int end) mut
	{
		data = mInput.Ptr;
		windowStart = 0;
		end = mInput.Length;
		if (mSettings.mMaxInputBytes > 0 && mInput.Length > mSettings.mMaxInputBytes)
			return .Err(InputError(.ResourceLimitExceeded, scope $"The input ({mInput.Length} bytes) exceeds MaxInputBytes ({mSettings.mMaxInputBytes})", 1, 1, 0, 0));
		int start = Try!(InputStart.Check(mInput.Ptr, mInput.Length, mSettings));
		mLines = .(start);
		if (TText.ValidatesUpFront)
		{
			let message = scope String();
			int bad = Utf8.FindInvalid<TText>(mInput.Ptr, start, mInput.Length, message, let kind, let length);
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
		int target = Math.Min(offset, mInput.Length);
		if (!mLines.CanReach(target))
		{
			// Behind the counter (an error before the last position asked for): count from the start
			Utf8.LineAndColumn<TText>(mInput, target, out line, out column);
			return true;
		}
		mLines.Locate(mInput.Ptr, target, mInput.Length, out line, out column);
		return true;
	}
}
