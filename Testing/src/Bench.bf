using System;
using System.Collections;
using System.Diagnostics;

namespace FormatCore.Testing;

/// @brief A timing result: the median of single timed runs.
public struct Measurement
{
	/// @brief The median sample, in nanoseconds.
	public double mMedianNs;
	/// @brief The number of samples taken.
	public int mSamples;
	/// @brief Whether the samples converged (else the time or sample cap stopped the run).
	public bool mConverged;
}

/// @brief The limits of the measuring rule. `Default` is the rule every harness in the siblings'
/// bench/compare shares (and bench-kit/bench-core.h's `measure()`).
public struct MeasureRule
{
	/// @brief Warm up for at least this long (at least one run).
	public double mWarmupSeconds;
	/// @brief Stop measuring after this long.
	public double mMaxSeconds;
	/// @brief Stop measuring after this many samples.
	public int mMaxSamples;
	/// @brief A sample is "within" when it lies within ±mWindow of the median (0.10: ±10%).
	public double mWindow;
	/// @brief Converged when at least this share of the samples is within (0.6).
	public double mMajority;

	/// @brief 1 s warm-up, 10 s or 1000 samples at most, 60% of the samples within ±10% of the median.
	public static MeasureRule Default => .() { mWarmupSeconds = 1, mMaxSeconds = 10, mMaxSamples = 1000, mWindow = 0.10, mMajority = 0.6 };
}

/// @brief The benchmark rule of the format libraries' testers and harnesses (six copies before:
/// TomlTester, KdlTester, XmlTester and the bench/compare Beef harnesses of TomlBeef, XmlBeef and
/// JsonBeef), and the input readers they use.
public static class Bench
{
	/// @brief Warm up for at least 1 s (at least one run), then time single runs until at least
	/// `minSamples` were taken and at least 60% of them lie within ±10% of their median ("converged"),
	/// or 10 s of measuring or 1000 samples have passed ("capped"). The median sample is reported.
	/// @param minSamples The fewest samples a converged result may have.
	/// @param op One operation to time.
	/// @return The result.
	public static Measurement Measure(int minSamples, delegate void() op)
	{
		return Measure(minSamples, op, .Default);
	}

	/// @brief Measure under another rule (tests use short limits).
	/// @param minSamples The fewest samples a converged result may have.
	/// @param op One operation to time.
	/// @param rule The limits.
	/// @return The result.
	public static Measurement Measure(int minSamples, delegate void() op, MeasureRule rule)
	{
		let watch = scope Stopwatch(true);
		repeat
			op();
		while (watch.Elapsed.TotalSeconds < rule.mWarmupSeconds);

		let samples = scope List<double>();
		let sorted = scope List<double>();
		watch.Restart();
		while (true)
		{
			let t0 = watch.Elapsed.Ticks;
			op();
			samples.Add((watch.Elapsed.Ticks - t0) * 100.0); // TimeSpan ticks are 100 ns
			sorted.Clear();
			sorted.AddRange(samples);
			sorted.Sort(scope (a, b) => a <=> b);
			int n = sorted.Count;
			double median = (n % 2 == 1) ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
			if (n >= minSamples && IsConverged(samples, median, rule))
				return .() { mMedianNs = median, mSamples = n, mConverged = true };
			if (n >= rule.mMaxSamples || watch.Elapsed.TotalSeconds >= rule.mMaxSeconds)
				return .() { mMedianNs = median, mSamples = n, mConverged = false };
		}
	}

	/// @brief Whether at least the rule's majority of `samples` lies within its window of `median`.
	/// @param samples The samples.
	/// @param median Their median.
	/// @param rule The rule.
	/// @return Whether they converged.
	public static bool IsConverged(Span<double> samples, double median, MeasureRule rule)
	{
		int within = 0;
		for (let s in samples)
		{
			if (s >= median * (1 - rule.mWindow) && s <= median * (1 + rule.mWindow))
				within++;
		}
		return within >= rule.mMajority * samples.Length;
	}

	/// @brief Append `<ms> ms/op <MB/s> MB/s (n=<samples>, converged|capped)`, as bench-core.h prints it.
	/// @param output The string to append to.
	/// @param m The result.
	/// @param bytes The input's size, for the throughput.
	public static void FormatResult(String output, Measurement m, int bytes)
	{
		double ms = m.mMedianNs / 1e6;
		double mbPerSecond = (double)bytes / 1048576.0 / (ms / 1000.0);
		output.AppendF("{0:F3} ms/op {1:F1} MB/s (n={2}, {3})", ms, mbPerSecond, m.mSamples, m.mConverged ? "converged" : "capped");
	}

	/// @brief Print the result line (FormatResult) to the console.
	/// @param m The result.
	/// @param bytes The input's size, for the throughput.
	public static void PrintResult(Measurement m, int bytes)
	{
		Console.WriteLine(FormatResult(.. scope .(), m, bytes));
	}
}
