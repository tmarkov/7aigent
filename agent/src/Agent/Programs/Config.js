import { parse } from "smol-toml";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const moduleDir = path.dirname(fileURLToPath(import.meta.url));

// parseTomlPure :: String -> { success, error, fields... }
export const parseTomlPure = (input) => {
    try {
        const obj = parse(input);
        const fields = [
            "api_endpoint", "model", "api_key_env",
            "output_threshold_chars", "max_api_retries",
            "max_tokens_per_turn", "compaction_threshold",
            "preserve_initial", "preserve_final",
            "max_turns_per_round", "max_repl_timeout_seconds"
        ];
        // Check for missing required fields
        for (const f of fields) {
            if (obj[f] === undefined || obj[f] === null) {
                return {
                    success: false,
                    error: f,
                    api_endpoint: "", model: "", api_key_env: "",
                    output_threshold_chars: 0, max_api_retries: 0,
                    max_tokens_per_turn: 0, compaction_threshold: 0,
                    preserve_initial: 0, preserve_final: 0,
                    max_turns_per_round: 0,
                    max_repl_timeout_seconds: 300,
                    progress_interval_seconds: 15
                };
            }
        }
        const pis = obj.progress_interval_seconds;
        const progress_interval_seconds =
            typeof pis === "number" ? pis : 15;
        return {
            success: true,
            error: "",
            api_endpoint: String(obj.api_endpoint),
            model: String(obj.model),
            api_key_env: String(obj.api_key_env),
            output_threshold_chars: Number(obj.output_threshold_chars),
            max_api_retries: Number(obj.max_api_retries),
            max_tokens_per_turn: Number(obj.max_tokens_per_turn),
            compaction_threshold: Number(obj.compaction_threshold),
            preserve_initial: Number(obj.preserve_initial),
            preserve_final: Number(obj.preserve_final),
            max_turns_per_round: Number(obj.max_turns_per_round),
            max_repl_timeout_seconds: Number(obj.max_repl_timeout_seconds),
            progress_interval_seconds
        };
    } catch (e) {
        return {
            success: false,
            error: e.message || "TOML parse error",
            api_endpoint: "", model: "", api_key_env: "",
            output_threshold_chars: 0, max_api_retries: 0,
            max_tokens_per_turn: 0, compaction_threshold: 0,
            preserve_initial: 0, preserve_final: 0,
            max_turns_per_round: 0,
            max_repl_timeout_seconds: 300,
            progress_interval_seconds: 15
        };
    }
};

// lookupEnvImpl :: String -> Effect (Nullable String)
export const lookupEnvImpl = (name) => () => {
    const val = process.env[name];
    return val === undefined ? null : val;
};

// lookupEnvSync :: String -> Nullable String
export const lookupEnvSync = (name) => {
    const val = process.env[name];
    return val === undefined ? null : val;
};

const bundledConfigCandidates = (name) => [
    path.resolve(moduleDir, "../../../config", name),
    path.resolve(process.cwd(), "config", name),
    path.resolve(process.cwd(), "agent", "config", name),
];

// readBundledDefaultImpl :: String -> Effect String
export const readBundledDefaultImpl = (name) => () => {
    for (const candidate of bundledConfigCandidates(name)) {
        if (fs.existsSync(candidate)) {
            return fs.readFileSync(candidate, "utf8");
        }
    }

    throw new Error("Bundled default config file not found: " + name);
};
