using Core;
using internal Core;

namespace FormatLib;

/// A sibling library opting into Core's internals: Core, InternalType and the sub-namespace Core.Detail.
public static class LibApi
{
	public static int Sum() => Shared.Internal + Shared.ProtectedInternal + InternalType.Value + Core.Detail.DetailThing.Value;

	internal static int LibInternal = 7;
}

/// A generic in FormatLib whose body touches Core internals; instantiated from App.
public static class LibGeneric<T>
{
	public static int Get() => Shared.Internal + sizeof(T);
}
