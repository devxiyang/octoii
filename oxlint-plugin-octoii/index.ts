/**
 * Octoii's own lint rules, which check what the repository asks of its code that oxlint's rules do not: oxlint loads this file
 * as a JS plugin named `octoii`.
 */
import { definePlugin } from "@oxlint/plugins";
import disableNeedsReason from "./rules/disable-needs-reason.ts";
import layerImports from "./rules/layer-imports.ts";
import noBooleanParameters from "./rules/no-boolean-parameters.ts";
import noDeadlinePolling from "./rules/no-deadline-polling.ts";
import noHandWrittenParsers from "./rules/no-hand-written-parsers.ts";
import noOtherProjectNames from "./rules/no-other-project-names.ts";
import noOffScale from "./rules/no-off-scale.ts";
import noOffTokenColors from "./rules/no-off-token-colors.ts";
import noRealWaits from "./rules/no-real-waits.ts";
import noRecordNames from "./rules/no-record-names.ts";
import noUnexplainedSkips from "./rules/no-unexplained-skips.ts";
import noUnknownReturn from "./rules/no-unknown-return.ts";
import noUseEffect from "./rules/no-use-effect.ts";
import noWallClock from "./rules/no-wall-clock.ts";
import noChainedTypeAssertions from "./rules/no-chained-type-assertions.ts";
import noCopiedRuntimeState from "./rules/no-copied-runtime-state.ts";
import noModelInCode from "./rules/no-model-in-code.ts";
import noModuleMocking from "./rules/no-module-mocking.ts";
import noReduceAccumulatorCopy from "./rules/no-reduce-accumulator-copy.ts";
import noWidenThenAssert from "./rules/no-widen-then-assert.ts";
import requireSafetyCommentForTypeAssertion from "./rules/require-safety-comment-for-type-assertion.ts";

export default definePlugin({
	meta: { name: "octoii" },
	rules: {
		"disable-needs-reason": disableNeedsReason,
		"no-boolean-parameters": noBooleanParameters,
		"no-other-project-names": noOtherProjectNames,
		"no-off-token-colors": noOffTokenColors,
		"no-off-scale": noOffScale,
		"no-record-names": noRecordNames,
		"no-real-waits": noRealWaits,
		"no-wall-clock": noWallClock,
		"no-deadline-polling": noDeadlinePolling,
		"no-unexplained-skips": noUnexplainedSkips,
		"no-chained-type-assertions": noChainedTypeAssertions,
		"no-widen-then-assert": noWidenThenAssert,
		"no-reduce-accumulator-copy": noReduceAccumulatorCopy,
		"no-module-mocking": noModuleMocking,
		"require-safety-comment-for-type-assertion": requireSafetyCommentForTypeAssertion,
		"no-hand-written-parsers": noHandWrittenParsers,
		"no-unknown-return": noUnknownReturn,
		"layer-imports": layerImports,
		"no-model-in-code": noModelInCode,
		"no-use-effect": noUseEffect,
		"no-copied-runtime-state": noCopiedRuntimeState,
	},
});
