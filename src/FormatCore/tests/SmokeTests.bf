using System;

namespace FormatCore;

static class SmokeTests
{
	[Test]
	public static void Workspace_Builds()
	{
		Test.Assert(FormatCoreVersion.Version.Length > 0);
	}
}
