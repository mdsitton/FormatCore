using System;
using Core;

namespace OtherLib;

/// In the workspace, unrelated to App: must not be visible to App's generation.
[Converter(typeof(int))]
public class OtherLibIntConverter
{
}
