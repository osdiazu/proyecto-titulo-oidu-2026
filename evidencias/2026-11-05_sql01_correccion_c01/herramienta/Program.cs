// Herramienta temporal (fuera del repositorio): analisis sintactico T-SQL con ScriptDom
// y verificacion cruzada de INSERT/UPDATE contra las definiciones de tablas.
// Uso: tsqlparse <archivo1.sql> <archivo2.sql> ... (en orden de ejecucion)
using System.Text.RegularExpressions;
using Microsoft.SqlServer.TransactSql.ScriptDom;

var vars = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
{
    ["UsuarioFunctionApp"] = "func-cobranza-prueba", ["UsuarioApi"] = "app-cobranza-prueba",
    ["DiasPreaviso"] = "5", ["DiasMora1"] = "10", ["DiasMora2"] = "30",
    ["CorreoPrueba1"] = "a@example.invalid", ["CorreoPrueba2"] = "b@example.invalid",
    ["Minutos"] = "1", ["Simulacro"] = "SIM",
};
var tablas = new Dictionary<string, Dictionary<string, Col>>(StringComparer.OrdinalIgnoreCase);
int errores = 0, hallazgos = 0;

foreach (var ruta in args)
{
    var nombre = Path.GetFileName(ruta);
    var texto = File.ReadAllText(ruta);
    var faltantes = new HashSet<string>();
    texto = Regex.Replace(texto, @"\$\((\w+)\)", m =>
    {
        if (vars.TryGetValue(m.Groups[1].Value, out var v)) return v;
        faltantes.Add(m.Groups[1].Value); return "X";
    });
    if (faltantes.Count > 0) Console.WriteLine($"[{nombre}] AVISO variables SQLCMD no definidas en la herramienta: {string.Join(",", faltantes)}");

    var parser = new TSql160Parser(initialQuotedIdentifiers: true);
    var frag = parser.Parse(new StringReader(texto), out var errs);
    foreach (var e in errs) { errores++; Console.WriteLine($"[{nombre}] ERROR SINTAXIS linea {e.Line}: {e.Message}"); }
    Console.WriteLine($"[{nombre}] sintaxis: {(errs.Count == 0 ? "OK" : errs.Count + " errores")}");
    if (errs.Count > 0) continue;

    var v2 = new Visitante(nombre, tablas);
    frag.Accept(v2);
    hallazgos += v2.Hallazgos;
}
Console.WriteLine($"TOTAL errores de sintaxis={errores}, hallazgos de columnas/CHECK={hallazgos}");
foreach (var (t, cols) in tablas.OrderBy(k => k.Key))
    Console.WriteLine($"  {t}: {string.Join(", ", cols.Values.Select(c => c.Nombre + (c.Obligatoria ? "*" : "") + (c.Dominio is null ? "" : "{" + string.Join("|", c.Dominio) + "}")))}");
return errores + hallazgos == 0 ? 0 : 1;

sealed record Col(string Nombre, bool Obligatoria, HashSet<string>? Dominio);

sealed class Visitante(string archivo, Dictionary<string, Dictionary<string, Col>> tablas) : TSqlFragmentVisitor
{
    public int Hallazgos;
    void H(TSqlFragment f, string m) { Hallazgos++; Console.WriteLine($"[{archivo}] HALLAZGO linea {f.StartLine}: {m}"); }
    static string N(SchemaObjectName n) => (n.SchemaIdentifier?.Value ?? "dbo") + "." + n.BaseIdentifier.Value;

    static Col ColDe(ColumnDefinition cd)
    {
        bool notNull = cd.Constraints.OfType<NullableConstraintDefinition>().Any(c => !c.Nullable)
                       || cd.Constraints.OfType<UniqueConstraintDefinition>().Any(u => u.IsPrimaryKey);
        bool tieneDefecto = cd.DefaultConstraint is not null || cd.IdentityOptions is not null || cd.ComputedColumnExpression is not null;
        HashSet<string>? dom = null;
        foreach (var ck in cd.Constraints.OfType<CheckConstraintDefinition>())
            if (ck.CheckCondition is InPredicate ip && !ip.NotDefined)
                dom = ip.Values.OfType<StringLiteral>().Select(s => s.Value).ToHashSet(StringComparer.OrdinalIgnoreCase) is { Count: > 0 } d ? d : null;
        // Columna calculada o identidad: no se puede insertar
        return new Col(cd.ColumnIdentifier.Value, notNull && !tieneDefecto, dom);
    }

    public override void Visit(CreateTableStatement node)
    {
        var t = N(node.SchemaObjectName);
        if (t.StartsWith("dbo.@") || node.SchemaObjectName.BaseIdentifier.Value.StartsWith("#")) return;
        if (tablas.ContainsKey(t)) { Console.WriteLine($"[{archivo}] info: {t} ya existe; su CREATE TABLE (con guarda) se omite."); return; }
        tablas[t] = node.Definition.ColumnDefinitions.ToDictionary(c => c.ColumnIdentifier.Value, ColDe, StringComparer.OrdinalIgnoreCase);
        foreach (var cd in node.Definition.ColumnDefinitions.Where(c => c.ComputedColumnExpression is not null || c.IdentityOptions is not null))
            tablas[t][cd.ColumnIdentifier.Value] = tablas[t][cd.ColumnIdentifier.Value] with { Nombre = cd.ColumnIdentifier.Value + "(auto)" };
    }

    public override void Visit(AlterTableAddTableElementStatement node)
    {
        var t = N(node.SchemaObjectName);
        if (!tablas.TryGetValue(t, out var cols)) { H(node, $"ALTER TABLE sobre {t} inexistente"); return; }
        foreach (var cd in node.Definition.ColumnDefinitions)
            if (!cols.ContainsKey(cd.ColumnIdentifier.Value)) { cols[cd.ColumnIdentifier.Value] = ColDe(cd); Console.WriteLine($"[{archivo}] info: se agrega {t}.{cd.ColumnIdentifier.Value}"); }
    }

    public override void Visit(InsertStatement node)
    {
        if (node.InsertSpecification.Target is not NamedTableReference ntr) return;
        var t = N(ntr.SchemaObject);
        if (!t.StartsWith("cob.") && !t.StartsWith("origen_sim.") && !t.StartsWith("ops.")) return;
        if (!tablas.TryGetValue(t, out var cols)) { H(node, $"INSERT en tabla no definida {t}"); return; }
        var lista = node.InsertSpecification.Columns.Select(c => c.MultiPartIdentifier.Identifiers.Last().Value).ToList();
        foreach (var c in lista)
            if (!cols.ContainsKey(c)) H(node, $"INSERT {t}: columna inexistente {c}");
            else if (cols[c].Nombre.EndsWith("(auto)")) H(node, $"INSERT {t}: columna calculada/identidad {c}");
        foreach (var c in cols.Values.Where(c => c.Obligatoria && !lista.Contains(c.Nombre, StringComparer.OrdinalIgnoreCase)))
            H(node, $"INSERT {t}: falta columna NOT NULL sin DEFAULT {c.Nombre}");
        // Literales contra CHECK
        IEnumerable<IList<ScalarExpression>> filas = node.InsertSpecification.InsertSource switch
        {
            ValuesInsertSource v => v.RowValues.Select(r => r.ColumnValues),
            SelectInsertSource s when s.Select is QuerySpecification q =>
                new[] { (IList<ScalarExpression>)q.SelectElements.Select(e => (e as SelectScalarExpression)?.Expression!).ToList() },
            _ => Array.Empty<IList<ScalarExpression>>()
        };
        foreach (var fila in filas)
            for (int i = 0; i < Math.Min(fila.Count, lista.Count); i++)
                if (fila[i] is StringLiteral sl && cols.TryGetValue(lista[i], out var col) && col.Dominio is not null && !col.Dominio.Contains(sl.Value))
                    H(fila[i], $"INSERT {t}.{lista[i]} = '{sl.Value}' no admitido por CHECK {{{string.Join("|", col.Dominio)}}}");
    }

    public override void Visit(UpdateSpecification node)
    {
        if (node.Target is not NamedTableReference ntr) return;
        var obj = ntr.SchemaObject;
        string? t = null;
        if (obj.SchemaIdentifier is not null) t = N(obj);
        else if (node.FromClause is not null)
            foreach (var tr in node.FromClause.TableReferences.SelectMany(Planas))
                if (tr is NamedTableReference n2 && n2.Alias?.Value.Equals(obj.BaseIdentifier.Value, StringComparison.OrdinalIgnoreCase) == true) t = N(n2.SchemaObject);
        if (t is null || !t.StartsWith("cob.")) return;
        if (!tablas.TryGetValue(t, out var cols)) { H(node, $"UPDATE tabla no definida {t}"); return; }
        foreach (var sc in node.SetClauses.OfType<AssignmentSetClause>())
        {
            var c = sc.Column?.MultiPartIdentifier.Identifiers.Last().Value;
            if (c is null) continue;
            if (!cols.ContainsKey(c)) H(node, $"UPDATE {t}: columna inexistente {c}");
            else if (sc.NewValue is StringLiteral sl && cols[c].Dominio is { } d && !d.Contains(sl.Value)) H(node, $"UPDATE {t}.{c} = '{sl.Value}' no admitido por CHECK");
        }
    }

    static IEnumerable<TableReference> Planas(TableReference tr) => tr switch
    {
        QualifiedJoin j => Planas(j.FirstTableReference).Concat(Planas(j.SecondTableReference)),
        UnqualifiedJoin u => Planas(u.FirstTableReference).Concat(Planas(u.SecondTableReference)),
        _ => new[] { tr }
    };
}
