using System;
using Core;
using FormatLib;
#if CASE_USING || CASE_PROTINT || CASE_SUBNS || CASE_INTERNAL_TYPE_USING
using internal Core;
#endif

namespace App;

#if CASE_GENERIC_APP
/// An App generic touching a Core internal without `using internal`.
static class AppGeneric<T>
{
	public static int Get() => Shared.Internal + sizeof(T);
}
#endif

class Program
{
	public static int Main()
	{
		// Always legal: Core's public API, visible through the transitive dependency App -> FormatLib -> Core
		int v = Shared.Public + LibApi.Sum();
		// A FormatLib generic using Core internals, specialized on an App type
		v += LibGeneric<Program>.Get();
		v += GenericHelper<int>.Get();
#if CASE_NO_USING
		v += Shared.Internal;                  // expected: inaccessible
#endif
#if CASE_USING
		v += Shared.Internal;
#endif
#if CASE_PROTINT
		v += Shared.ProtectedInternal;
#endif
#if CASE_SUBNS
		v += Core.Detail.DetailThing.Value;    // `using internal Core` covers Core.Detail
#endif
#if CASE_INTERNAL_TYPE
		v += InternalType.Value;               // expected: inaccessible
#endif
#if CASE_INTERNAL_TYPE_DECL
		InternalType declared = null;          // the type in a declaration (a type reference)
		v += (declared == null) ? 1 : 0;
#endif
#if CASE_INTERNAL_TYPE_QUALIFIED
		v += Core.InternalType.Value;          // qualified member access
#endif
#if CASE_INTERNAL_TYPE_USING
		v += InternalType.Value;
#endif
#if CASE_FRIEND
		v += Shared.[Friend]sPrivate;          // [Friend] at the use site: private, no `using internal`
		v += Shared.[Friend]Internal;
#endif
#if CASE_LIB_INTERNAL
		v += LibApi.LibInternal;               // expected: inaccessible (no `using internal FormatLib`)
#endif
#if CASE_GENERIC_APP
		v += AppGeneric<int>.Get();
#endif
		Console.WriteLine(v);
		return 0;
	}
}
