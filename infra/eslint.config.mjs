import awscdk from "eslint-plugin-awscdk";
import tseslint from "typescript-eslint";

export default tseslint.config(
  ...tseslint.configs.recommended,
  {
    files: ["bin/**/*.ts", "lib/**/*.ts"],
    plugins: { awscdk },
    rules: {
      "awscdk/no-parent-name-construct-id-match": "error",
      "@typescript-eslint/no-explicit-any": "error",
    },
  },
);
