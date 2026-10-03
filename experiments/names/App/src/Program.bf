using System;
#if !N4_NOUSING
using Core;
#endif
#if N1_BOTH || N3_ATTR
using LibX;
#endif

#if N7_SAME_FULL_NAME
namespace Core
{
	/// App declaring a type with the same full name as a Core type.
	public struct Cursor
	{
	}
}
#endif

namespace App
{
#if N2_OWN || N4_CAPTURE || N4_NOUSING
	/// App's own Cursor, same short name as Core.Cursor.
	struct Cursor
	{
		public static int Id => 3;
	}
#endif

#if N4_CAPTURE || N4_NOUSING
	/// Unqualified emitted code inside an App type, App.Cursor in scope.
	[Core.EmitUnqualified]
	class Captured
	{
	}
#endif

#if N5_SHADOW
	/// Qualified emitted code inside an App type with a member named Core.
	[EmitQualified]
	class Shadowed
	{
		public static int Core = 5;
	}
#endif

#if N5_GLOBAL
	[EmitTypeof]
	class Shadowed
	{
		public static int Core = 5;
	}
#endif

	[Core.EmitQualified]
	class Qualified
	{
	}

#if N3_ATTR
	[Object]
	class Tagged
	{
	}
#endif

	class Program
	{
		public static int Main()
		{
			Console.WriteLine(scope $"Qualified.EmittedId={Qualified.EmittedId}");
#if N1_BOTH || N2_OWN
			Console.WriteLine(scope $"Cursor.Id={Cursor.Id}");
#endif
#if N4_CAPTURE || N4_NOUSING
			Console.WriteLine(scope $"Captured.EmittedId={Captured.EmittedId} (1 = Core.Cursor, 3 = App.Cursor)");
#endif
#if N5_SHADOW || N5_GLOBAL
			Console.WriteLine(scope $"Shadowed.EmittedId={Shadowed.EmittedId}");
#endif
			return 0;
		}
	}
}
