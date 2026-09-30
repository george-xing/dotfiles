export const toolDefinitions = [
  {
    name: "whatsapp_status",
    description: "Report whether the local WhatsApp Web session is authenticated and ready.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {},
    },
  },
  {
    name: "whatsapp_list_groups",
    description: "List WhatsApp group chats visible to the authenticated WhatsApp Web session.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        query: {
          type: "string",
          description: "Optional case-insensitive group name filter.",
        },
        limit: {
          type: "number",
          description: "Maximum number of groups to return. Defaults to 100, max 500.",
        },
      },
    },
  },
  {
    name: "whatsapp_read_group_messages",
    description: "Read recent messages from one WhatsApp group chat. This tool is read-only.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["groupId"],
      properties: {
        groupId: {
          type: "string",
          description: "WhatsApp group JID, usually ending in @g.us.",
        },
        limit: {
          type: "number",
          description: "Number of recent messages to fetch. Defaults to 200, max 500.",
        },
        afterTimestamp: {
          type: "number",
          description: "Optional WhatsApp epoch-seconds cursor; older messages are filtered out.",
        },
      },
    },
  },
];
