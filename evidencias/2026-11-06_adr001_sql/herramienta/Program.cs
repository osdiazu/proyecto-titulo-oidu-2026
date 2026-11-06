// Herramienta de analisis estatico T-SQL (v2, 06-11-2026). Se compila FUERA del repositorio.
// v1: evidencias/2026-11-05_sql01_correccion_c01/herramienta (sintaxis ScriptDom e INSERT/UPDATE
//     contra definiciones de tablas y CHECK de tipo IN).
// v2 agrega:
//   - EXEC: el procedimiento cob.* existe, los parametros con nombre existen y los obligatorios
//     (sin valor por defecto) se entregan.
//   - GRANT: el objeto existe; lista de concesiones por principal.
//   - Procedimientos con GRANT que leen cob.LogAcceso (ADR-001 5.1): hallazgo.
//   - THROW: numeros por archivo; en 12 y 13 deben estar en 50060-50079 (ADR-001 5.2).
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
var est = new Estado();
est.Objetos.Add("cob.ListaRut"); // se crea con EXEC (cadena) en 01: ScriptDom no lo ve como objeto
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

    var v2 = new Visitante(nombre, est);
    frag.Accept(v2);
    hallazgos += v2.Hallazgos;
    if (v2.Throws.Count > 0)
    {
        var fuera = (nombre.StartsWith("12_") || nombre.StartsWith("13_")) ? v2.Throws.Where(n => n < 50060 || n > 50079).ToList() : new List<int>();
        Console.WriteLine($"[{nombre}] THROW: {string.Join(",", v2.Throws.Distinct().OrderBy(n => n))}" + (fuera.Count > 0 ? $"  FUERA DE RANGO 50060-50079: {string.Join(",", fuera)}" : ""));
        if (fuera.Count > 0) hallazgos += fuera.Count;
    }
}
Console.WriteLine($"TOTAL errores de sintaxis={errores}, hallazgos={hallazgos}");
foreach (var (t, cols) in est.Tablas.OrderBy(k => k.Key))
    Console.WriteLine($"  {t}: {string.Join(", ", cols.Values.Select(c => c.Nombre + (c.Obligatoria ? "*" : "") + (c.Dominio is null ? "" : "{" + string.Join("|", c.Dominio) + "}")))}");
Console.WriteLine("GRANT por principal:");
foreach (var g in est.Grants.GroupBy(g => g.Principal).OrderBy(g => g.Key))
    Console.WriteLine($"  {g.Key}: {string.Join("; ", g.Select(x => $"{x.Permiso} {x.Objeto} ({x.Archivo})"))}");
Console.WriteLine("Procedimientos cob.* que leen cob.LogAcceso (FROM/JOIN; no cuenta INSERT INTO):");
foreach (var p in est.LeenLogAcceso.OrderBy(x => x)) Console.WriteLine($"  {p}");
return errores + hallazgos == 0 ? 0 : 1;

sealed record Col(string Nombre, bool Obligatoria, HashSet<string>? Dominio);
sealed record Param(string Nombre, bool TieneDefecto);
sealed record Concesion(string Principal, string Permiso, string Objeto, string Archivo);

sealed class Estado
{
    public Dictionary<string, Dictionary<string, Col>> Tablas = new(StringComparer.OrdinalIgnoreCase);
    public Dictionary<string, List<Param>> Procs = new(StringComparer.OrdinalIgnoreCase);
    public HashSet<string> Objetos = new(StringComparer.OrdinalIgnoreCase);
    public HashSet<string> LeenLogAcceso = new(StringComparer.OrdinalIgnoreCase);
    public List<Concesion> Grants = new();
}

// Recolecta tablas leidas (FROM/JOIN) y destinos de INSERT dentro de un cuerpo de procedimiento
sealed class Lecturas : TSqlFragmentVisitor
{
    public List<NamedTableReference> Todas = new();
    public HashSet<TSqlFragment> Destinos = new();
    public override void Visit(NamedTableReference node) => Todas.Add(node);
    public override void Visit(InsertSpecification node) { if (node.Target is not null) Destinos.Add(node.Target); }
}

sealed class Visitante(string archivo, Estado est) : TSqlFragmentVisitor
{
    public int Hallazgos;
    public List<int> Throws = new();
    void H(TSqlFragment f, string m) { Hallazgos++; Console.WriteLine($"[{archivo}] HALLAZGO linea {f.StartLine}: {m}"); }
    static string N(SchemaObjectName n) => (n.SchemaIdentifier?.Value ?? "dbo") + "." + n.BaseIdentifier.Value;
    static string N(MultiPartIdentifier m) => m.Identifiers.Count >= 2
        ? m.Identifiers[^2].Value + "." + m.Identifiers[^1].Value : "dbo." + m.Identifiers[^1].Value;

    static Col ColDe(ColumnDefinition cd)
    {
        bool notNull = cd.Constraints.OfType<NullableConstraintDefinition>().Any(c => !c.Nullable)
                       || cd.Constraints.OfType<UniqueConstraintDefinition>().Any(u => u.IsPrimaryKey);
        bool tieneDefecto = cd.DefaultConstraint is not null || cd.IdentityOptions is not null || cd.ComputedColumnExpression is not null;
        HashSet<string>? dom = null;
        foreach (var ck in cd.Constraints.OfType<CheckConstraintDefinition>())
            if (ck.CheckCondition is InPredicate ip && !ip.NotDefined)
                dom = ip.Values.OfType<StringLiteral>().Select(s => s.Value).ToHashSet(StringComparer.OrdinalIgnoreCase) is { Count: > 0 } d ? d : null;
        return new Col(cd.ColumnIdentifier.Value, notNull && !tieneDefecto, dom);
    }

    public override void Visit(CreateTableStatement node)
    {
        var t = N(node.SchemaObjectName);
        if (t.StartsWith("dbo.@") || node.SchemaObjectName.BaseIdentifier.Value.StartsWith("#")) return;
        est.Objetos.Add(t);
        if (est.Tablas.ContainsKey(t)) { Console.WriteLine($"[{archivo}] info: {t} ya existe; su CREATE TABLE (con guarda) se omite."); return; }
        est.Tablas[t] = node.Definition.ColumnDefinitions.ToDictionary(c => c.ColumnIdentifier.Value, ColDe, StringComparer.OrdinalIgnoreCase);
        foreach (var cd in node.Definition.ColumnDefinitions.Where(c => c.ComputedColumnExpression is not null || c.IdentityOptions is not null))
            est.Tablas[t][cd.ColumnIdentifier.Value] = est.Tablas[t][cd.ColumnIdentifier.Value] with { Nombre = cd.ColumnIdentifier.Value + "(auto)" };
    }

    public override void Visit(ViewStatementBody node) => est.Objetos.Add(N(node.SchemaObjectName));
    public override void Visit(FunctionStatementBody node) => est.Objetos.Add(N(node.Name));
    public override void Visit(TriggerStatementBody node) => est.Objetos.Add(N(node.Name));

    public override void Visit(ProcedureStatementBody node)
    {
        var p = N(node.ProcedureReference.Name);
        est.Objetos.Add(p);
        est.Procs[p] = node.Parameters.Select(x => new Param(x.VariableName.Value, x.Value is not null)).ToList();
        var l = new Lecturas();
        node.StatementList?.Accept(l);
        if (l.Todas.Any(t => N(t.SchemaObject).Equals("cob.LogAcceso", StringComparison.OrdinalIgnoreCase) && !l.Destinos.Contains(t)))
            est.LeenLogAcceso.Add(p);
        else est.LeenLogAcceso.Remove(p);
    }

    public override void Visit(ExecuteSpecification node)
    {
        if (node.ExecutableEntity is not ExecutableProcedureReference epr) return;
        var pr = epr.ProcedureReference?.ProcedureReference;
        if (pr is null) return;
        var nombre = N(pr.Name);
        if (!nombre.StartsWith("cob.", StringComparison.OrdinalIgnoreCase)) return;
        if (!est.Procs.TryGetValue(nombre, out var ps)) { H(node, $"EXEC de procedimiento no definido {nombre}"); return; }
        var dados = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        int pos = 0;
        foreach (var a in epr.Parameters)
        {
            if (a.Variable is null) { if (pos < ps.Count) dados.Add(ps[pos].Nombre); else H(node, $"EXEC {nombre}: demasiados parametros posicionales"); pos++; continue; }
            if (!ps.Any(x => x.Nombre.Equals(a.Variable.Name, StringComparison.OrdinalIgnoreCase))) H(node, $"EXEC {nombre}: parametro inexistente {a.Variable.Name}");
            dados.Add(a.Variable.Name);
        }
        foreach (var x in ps.Where(x => !x.TieneDefecto && !dados.Contains(x.Nombre)))
            H(node, $"EXEC {nombre}: falta parametro obligatorio {x.Nombre}");
    }

    public override void Visit(GrantStatement node)
    {
        var obj = node.SecurityTargetObject?.ObjectName?.MultiPartIdentifier;
        if (obj is null) return;
        var o = N(obj);
        var perm = string.Join(" ", node.Permissions.SelectMany(p => p.Identifiers).Select(i => i.Value));
        foreach (var pr in node.Principals) est.Grants.Add(new Concesion(pr.Identifier?.Value ?? pr.PrincipalType.ToString(), perm, o, archivo));
        if (!est.Objetos.Contains(o)) H(node, $"GRANT sobre objeto no definido {o}");
        if (est.LeenLogAcceso.Contains(o)) H(node, $"GRANT sobre {o}, que lee cob.LogAcceso (ADR-001 5.1)");
        if (o.Equals("cob.LogAcceso", StringComparison.OrdinalIgnoreCase) || o.Equals("cob.vw_LogAccesoEvidencia", StringComparison.OrdinalIgnoreCase))
            H(node, $"GRANT directo sobre {o} (ADR-001 5.1)");
    }

    public override void Visit(ThrowStatement node)
    {
        if (node.ErrorNumber is IntegerLiteral il && int.TryParse(il.Value, out var n)) Throws.Add(n);
    }

    public override void Visit(AlterTableAddTableElementStatement node)
    {
        var t = N(node.SchemaObjectName);
        if (!est.Tablas.TryGetValue(t, out var cols)) { H(node, $"ALTER TABLE sobre {t} inexistente"); return; }
        foreach (var cd in node.Definition.ColumnDefinitions)
            if (!cols.ContainsKey(cd.ColumnIdentifier.Value)) { cols[cd.ColumnIdentifier.Value] = ColDe(cd); Console.WriteLine($"[{archivo}] info: se agrega {t}.{cd.ColumnIdentifier.Value}"); }
    }

    public override void Visit(InsertStatement node)
    {
        if (node.InsertSpecification.Target is not NamedTableReference ntr) return;
        var t = N(ntr.SchemaObject);
        if (!t.StartsWith("cob.") && !t.StartsWith("origen_sim.") && !t.StartsWith("ops.")) return;
        if (!est.Tablas.TryGetValue(t, out var cols)) { H(node, $"INSERT en tabla no definida {t}"); return; }
        var lista = node.InsertSpecification.Columns.Select(c => c.MultiPartIdentifier.Identifiers.Last().Value).ToList();
        foreach (var c in lista)
            if (!cols.ContainsKey(c)) H(node, $"INSERT {t}: columna inexistente {c}");
            else if (cols[c].Nombre.EndsWith("(auto)")) H(node, $"INSERT {t}: columna calculada/identidad {c}");
        foreach (var c in cols.Values.Where(c => c.Obligatoria && !lista.Contains(c.Nombre, StringComparer.OrdinalIgnoreCase)))
            H(node, $"INSERT {t}: falta columna NOT NULL sin DEFAULT {c.Nombre}");
        IEnumerable<IList<ScalarExpression>> filas = node.InsertSpecification.InsertSource switch
        {
            ValuesInsertSource v => v.RowValues.Select(r => r.ColumnValues),
            SelectInsertSource s when s.Select is QuerySpecification q =>
                new[] { (IList<ScalarExpression>)q.SelectElements.Select(e => (e as SelectScalarExpression)?.Expression!).ToList() },
            _ => Array.Empty<IList<ScalarExpression>>()
        };
        foreach (var fila in filas)
        {
            if (fila.Count != lista.Count && lista.Count > 0) H(node, $"INSERT {t}: {lista.Count} columnas y {fila.Count} valores");
            for (int i = 0; i < Math.Min(fila.Count, lista.Count); i++)
                if (fila[i] is StringLiteral sl && cols.TryGetValue(lista[i], out var col) && col.Dominio is not null && !col.Dominio.Contains(sl.Value))
                    H(fila[i], $"INSERT {t}.{lista[i]} = '{sl.Value}' no admitido por CHECK {{{string.Join("|", col.Dominio)}}}");
        }
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
        if (!est.Tablas.TryGetValue(t, out var cols)) { H(node, $"UPDATE tabla no definida {t}"); return; }
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
