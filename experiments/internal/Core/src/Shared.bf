#if !CASE_CORE_NO_USING
using internal Core;
#endif

namespace Core;

public class Shared
{
	public static int Public = 1;
	internal static int Internal = 2;
	protected internal static int ProtectedInternal = 3;
	static int sPrivate = 4;
}

internal class InternalType
{
	public static int Value = 5;
}

/// A generic whose body uses an internal member (with `using internal` in this file it is legal here).
public static class GenericHelper<T>
{
	public static int Get() => Shared.Internal + sizeof(T);
}
