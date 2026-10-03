using System;

namespace FormatCore.Mapping;

/// @brief How a typed mapping turns declared names (fields, enum cases, types) into the format's
/// names: the union of the four format libraries' naming enums. Words split at case changes, keeping
/// acronyms together (`HTTPPort` is `http_port` in SnakeCase), and at underscores.
public enum NamingPolicy
{
	/// @brief The name as written: `poolSize`, `PoolSize`, `pool_size`.
	AsDeclared,
	/// @brief `poolSize`.
	CamelCase,
	/// @brief `PoolSize`.
	PascalCase,
	/// @brief `pool_size`.
	SnakeCase,
	/// @brief `pool-size`.
	KebabCase,
	/// @brief `poolsize`: the words lower-cased with no separator (XmlBeef's Lower).
	Lower
}

/// @brief The word splitter all four generators copied (JsonBeef's, plus XmlBeef's Lower). An ordinary
/// method: generators call it at compile time, tools at run time.
public static class Naming
{
	/// @brief Append the name `name` takes under `policy`. Words start at an upper-case letter that
	/// follows a lower-case letter or digit, or that ends an acronym (the last capital before a
	/// lower-case letter), so `HTTPPort` splits as HTTP, Port; underscores also split (and are dropped
	/// unless the policy is AsDeclared).
	/// @param name The declared name.
	/// @param policy The naming policy.
	/// @param result The string to append to.
	public static void Apply(StringView name, NamingPolicy policy, String result)
	{
		if (policy == .AsDeclared)
		{
			result.Append(name);
			return;
		}
		int words = 0;
		int i = 0;
		while (i < name.Length)
		{
			if (name[i] == '_')
			{
				i++;
				continue;
			}
			int start = i++;
			while (i < name.Length && name[i] != '_' && !(name[i].IsUpper && (name[i - 1].IsLower || name[i - 1].IsDigit ||
				(name[i - 1].IsUpper && i + 1 < name.Length && name[i + 1].IsLower))))
				i++;

			if (words > 0 && (policy == .KebabCase || policy == .SnakeCase))
				result.Append(policy == .KebabCase ? '-' : '_');
			for (int j = start; j < i; j++)
			{
				bool upper = (j == start) && (policy == .PascalCase || (policy == .CamelCase && words > 0));
				result.Append(upper ? name[j].ToUpper : name[j].ToLower);
			}
			words++;
		}
	}
}
