using System;
using internal FormatCore;

namespace FormatCore;

/// The collect-errors skeleton the readers share (KdlBeef, XmlBeef and JsonBeef's AfterError): whether
/// to stop after an error, and where recovery may restart so that it always makes progress. The
/// resynchronization itself stays in each format.
internal struct ErrorPolicy
{
	/// Whether errors are collected at all (the config's CollectErrors).
	public bool mCollect;
	/// Stop after this many errors (0: no limit; the config's MaxErrors).
	public int mMaxErrors;
	/// Errors seen so far.
	public int mCount;
	/// The last error's recovery anchor (-1: none yet).
	public int64 mLastAnchor = -1;

	/// @brief A policy for one read.
	/// @param collect Whether errors are collected.
	/// @param maxErrors The maximum number of errors (0: no limit).
	public this(bool collect, int maxErrors)
	{
		mCollect = collect;
		mMaxErrors = maxErrors;
		mCount = 0;
		mLastAnchor = -1;
	}

	/// @brief Counts an error and says whether the read must stop: when errors are not collected, when
	/// the error is fatal (the input itself failed, a limit, an encoding error, an error before the
	/// first construct: the format decides), or when MaxErrors is reached.
	/// @param fatal Whether the format considers this error fatal.
	/// @return Whether to stop.
	public bool ShouldStop(bool fatal) mut
	{
		if (!mCollect || fatal)
			return true;
		return mMaxErrors > 0 && ++mCount >= mMaxErrors;
	}

	/// @brief Where recovery restarts for an error at `offset`: the offset, or one past the last anchor
	/// when the error is not after it (so two errors at the same place cannot loop).
	/// @param offset The error's offset.
	/// @return The anchor.
	public int64 Anchor(int64 offset) mut
	{
		int64 anchor = offset;
		if (anchor <= mLastAnchor)
			anchor = mLastAnchor + 1;
		mLastAnchor = anchor;
		return anchor;
	}
}

/// Resource-limit checks and their messages, as every format writes them ("X exceeds MaxY (n)").
internal static class Limits
{
	/// @brief Whether `value` exceeds `limit` (a limit of 0 or less is no limit). The value is computed
	/// before the call, whatever the limit: never pass an expression with a side effect on a hot path
	/// (`Exceeds(max, ++count)` counts even with no limit set, where `max > 0 && ++count > max` does
	/// not; KdlBeef measured 1% on a per-entry counter).
	/// @param limit The limit.
	/// @param value The value.
	/// @return Whether it is exceeded.
	[Inline]
	public static bool Exceeds(int limit, int value)
	{
		return limit > 0 && value > limit;
	}

	/// @brief Append `what exceeds setting (limit)`.
	/// @param message The string to append to.
	/// @param what What is too large ("The input (12 bytes)", "The nesting depth").
	/// @param setting The config setting's name ("MaxInputBytes").
	/// @param limit The limit.
	public static void AppendExceeded(String message, StringView what, StringView setting, int limit)
	{
		message.AppendF("{} exceeds {} ({})", what, setting, limit);
	}
}
