import { execSync } from "node:child_process";

// isPureDefinitionImpl :: String -> Boolean
// Parses the Julia expression using Meta.parse and checks if the resulting
// Expr head indicates a pure definition.
export const isPureDefinitionImpl = (code) => {
    const trimmed = code.trim();
    if (!trimmed) return false;

    // Use Julia's Meta.parse to get the AST, then check the head
    // The Julia script outputs "true" or "false"
    const juliaScript = `
        expr = Meta.parse(${JSON.stringify(trimmed)})
        function is_pure_def(e)
            if isa(e, Symbol)
                return false
            end
            if !isa(e, Expr)
                return false
            end
            h = e.head
            if h === :function || h === :macro || h === :struct ||
               h === :abstract || h === :primitive
                return true
            end
            # Short-form method: f(x) = expr  →  head is :(=), LHS head is :call
            if h === :(=) && length(e.args) >= 1
                lhs = e.args[1]
                if isa(lhs, Expr) && lhs.head === :call
                    return true
                end
                # const is also :(=) but wrapped in :const
            end
            # macrocall: @enum, @kwdef
            if h === :macrocall
                macro_name = e.args[1]
                name_str = string(macro_name)
                if contains(name_str, "enum") || contains(name_str, "kwdef")
                    return true
                end
            end
            # const with simple RHS
            if h === :const
                inner = e.args[1]
                if isa(inner, Expr) && inner.head === :(=) && length(inner.args) >= 2
                    rhs = inner.args[2]
                    # Simple identifier
                    if isa(rhs, Symbol)
                        return true
                    end
                    # Parameterised type (curly) or Union
                    if isa(rhs, Expr) && rhs.head === :curly
                        return true
                    end
                end
            end
            return false
        end
        println(is_pure_def(expr))
    `;

    try {
        const result = execSync("julia -e " + shellQuote(juliaScript), {
            encoding: "utf8",
            timeout: 10000,
            stdio: ["pipe", "pipe", "pipe"],
        }).trim();
        return result === "true";
    } catch (_e) {
        return false;
    }
};

function shellQuote(s) {
    return "'" + s.replace(/'/g, "'\\''") + "'";
}
