export const setTestEnv = () => {
    process.env["TEST_7AIGENT_KEY"] = "sk-test-mock-key-12345";
};

export const unsetTestEnv = () => {
    delete process.env["TEST_7AIGENT_KEY"];
};
