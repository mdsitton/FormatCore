using System;

namespace FormatCore;

/// @brief The library's version: matches the release tag (`vMAJOR.MINOR.PATCH`) the format libraries
/// pin with `FormatCore = {Git = "...", Version = "MAJOR.MINOR"}`.
public static class FormatCoreVersion
{
	/// @brief Semantic version of the shared core.
	public const String Version = "0.1.3";
}
