using System;
using System.Collections;
using System.Reflection;
using Core;

namespace FormatLib;

/// The format library's role attribute, handed to Core's generic planner as TRoleAttr.
[AttributeUsage(.Field)]
public struct XElementAttribute : Attribute, IRoleAttribute
{
	public StringView Role => "element";
}

/// The format, handed to Core's planner as TFormat (static interface dispatch at comptime).
public struct XFormat : IMappingFormat
{
	public static StringView FormatName => "X";

	public static void AssignRole(FieldInfo field, String outRole)
	{
		outRole.Append(field.FieldType.IsPrimitive ? "attribute" : "child");
	}
}

public interface IXSerializable
{
	StringView XPlan { get; }
}

/// Two hops: FormatLib's attribute, applied to UserLib and App types, generating through Core.
[AttributeUsage(.Class | .Struct)]
public struct XObjectAttribute : Attribute, IComptimeTypeApply
{
	[Comptime]
	public void ApplyToType(Type type)
	{
		XCodeGen.Emit(type);
	}
}

class CountingVisitor : IPlanVisitor
{
	public int mCount;

	public void Visit(MemberPlan plan)
	{
		mCount++;
	}
}

public static class XCodeGen
{
	[Comptime]
	public static void Emit(Type type)
	{
		let plans = scope List<MemberPlan>();
		// Q4: Core-allocated plans, freed here
		defer { ClearAndDeleteItems!(plans); }
		Planner<XFormat, XElementAttribute>.Plan(type, plans);

		let text = scope String();
		text.AppendF("type={} format={} {} plans:[", type.GetFullName(.. scope .()), Planner<XFormat, XElementAttribute>.FormatName, Planner<XFormat, XElementAttribute>.Version);
		let visitor = scope CountingVisitor();
		for (let plan in plans)
		{
			plan.Describe(text);
			text.Append(' ');
			plan.Accept(visitor);
		}
		text.AppendF("] visited={} PlanCache.sPlans={} kebab=", visitor.mCount, PlanCache.sPlans);
		Naming.Kebab(type.GetName(.. scope .()), text);
		text.AppendF(" ProjectName@FormatLib={} ", Compiler.ProjectName);
		CoreRegistry.Describe(text);
		text.Append(" decls@FormatLib:[");
		CoreRegistry.DescribeDecls(text);
		text.Append("]");

		Compiler.EmitAddInterface(type, typeof(IXSerializable));
		Compiler.EmitTypeBody(type, scope $"public StringView XPlan => {Literal.Append(.. scope .(), text)};\n");
		// Generated code that calls back into Core comptime through Compiler.Mixin (as the siblings' dispatch does)
		Compiler.EmitTypeBody(type, "public static StringView MixinDecls\n{\n\tget\n\t{\n\t\tSystem.Compiler.Mixin(Core.CoreRegistry.DescribeAsCode());\n\t}\n}\n");
		// The same through a [Comptime] entry method emitted into the user type itself
		Compiler.EmitTypeBody(type, "[Comptime]\nstatic String DeclsCode_() => Core.CoreRegistry.DescribeAsCode();\npublic static StringView MixinDeclsLocal\n{\n\tget\n\t{\n\t\tSystem.Compiler.Mixin(DeclsCode_());\n\t}\n}\n");
	}
}

[Converter(typeof(int))]
public class FormatLibIntConverter
{
}
