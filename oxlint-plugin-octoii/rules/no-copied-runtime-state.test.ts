import { ruleTester } from "../test/harness.ts";

const rule = ruleTester("no-copied-runtime-state");

const IMPORT = "import { useChats, useChatLog } from '@octoii-works/octoii-client/react';\n";
const MESSAGE = (name: string): string => `The runtime's data is read from its hook, not copied into ${name}: a copy stops following the runtime.`;

rule.valid("a hook's answer read as it is", `${IMPORT}const chats = useChats();\nconst first = chats.rows[0];`);
rule.valid("state of what the person does", `${IMPORT}const chats = useChats();\nconst [draft, setDraft] = useState("");`);
rule.valid("a function of the same name from elsewhere", "import { useChats } from './chats.ts';\nconst [rows] = useState(useChats().rows);");

rule.invalid("a hook's answer as the first state", `${IMPORT}const [chats] = useState(useChats());`, MESSAGE("useState"));
rule.invalid("a member of a hook's answer", `${IMPORT}const chats = useChats();\nconst [rows] = useState(chats.rows);`, MESSAGE("useState"));
rule.invalid(
	"a name destructured from a hook's answer",
	`${IMPORT}const { entries } = useChatLog(chat);\nconst [kept] = useState(entries);`,
	MESSAGE("useState"),
);
rule.invalid("a reducer's first state", `${IMPORT}const log = useChatLog(chat);\nconst [state] = useReducer(reduce, log.entries);`, MESSAGE("useReducer"));
rule.invalid("a hook's answer through React's namespace", `${IMPORT}const chats = useChats();\nReact.useState(chats);`, MESSAGE("useState"));
