function jsonContent(value) {
  return {
    content: [
      {
        type: "text",
        text: JSON.stringify(value, null, 2),
      },
    ],
  };
}

export async function dispatchToolCall({ name, args, status, tools }) {
  switch (name) {
    case "whatsapp_status":
      return jsonContent(status());
    case "whatsapp_list_groups":
      return jsonContent(await tools.listGroups(args ?? {}));
    case "whatsapp_read_group_messages":
      return jsonContent(await tools.readGroupMessages(args ?? {}));
    default:
      throw new Error(`Unknown tool: ${name}`);
  }
}
