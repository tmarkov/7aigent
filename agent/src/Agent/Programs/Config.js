import { parse } from "smol-toml";

// parseTomlPure :: String -> { success, error, fields... }
export const parseTomlPure = (input) => {
    try {
        const obj = parse(input);
        const fields = [
            "api_endpoint", "model", "api_key_env",
            "output_threshold_chars", "max_api_retries",
            "max_tokens_per_turn", "compaction_threshold",
            "preserve_initial", "preserve_final"
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
                    preserve_initial: 0, preserve_final: 0
                };
            }
        }
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
            preserve_final: Number(obj.preserve_final)
        };
    } catch (e) {
        return {
            success: false,
            error: e.message || "TOML parse error",
            api_endpoint: "", model: "", api_key_env: "",
            output_threshold_chars: 0, max_api_retries: 0,
            max_tokens_per_turn: 0, compaction_threshold: 0,
            preserve_initial: 0, preserve_final: 0
        };
    }
};

// lookupEnvImpl :: String -> Effect (Nullable String)
export const lookupEnvImpl = (name) => () => {
    const val = process.env[name];
    return val === undefined ? null : val;
};
