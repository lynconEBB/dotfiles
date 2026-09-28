local ls = require("luasnip")
local s, t, i, d, sn = ls.snippet, ls.text_node, ls.insert_node, ls.dynamic_node, ls.snippet_node

local function unity_class(base_class)
  local directory = vim.fn.expand("%:p:h"):gsub("\\", "/")
  local folders = directory:match("/Assets/(.+)$")
  local namespace = folders and folders:gsub("/", ".")
  local class_name = vim.fn.expand("%:t:r")
  local indent = namespace and "    " or ""
  local nodes = { t({ "using UnityEngine;", "", "" }) }

  if namespace then
    table.insert(nodes, t({ "namespace " .. namespace, "{", indent }))
  end

  local body_index = 1
  if base_class == "ScriptableObject" then
    table.insert(nodes, t('[CreateAssetMenu(fileName = "' .. class_name .. '", menuName = "'))
    table.insert(nodes, i(1, "ScriptableObjects/"))
    table.insert(nodes, t({ class_name .. '")]', indent }))
    body_index = 2
  end

  table.insert(nodes, t({ "public class " .. class_name .. " : " .. base_class, indent .. "{", indent .. "    " }))
  table.insert(nodes, i(body_index))
  table.insert(nodes, t({ "", indent .. "}" }))
  if namespace then table.insert(nodes, t({ "", "}" })) end

  return sn(nil, nodes)
end

return {
  s("start", { t({ "void Start()", "{", "    " }), i(1), t({ "", "}" }) }),
  s("update", { t({ "void Update()", "{", "    " }), i(1), t({ "", "}" }) }),
  s("awake", { t({ "void Awake()", "{", "    " }), i(1), t({ "", "}" }) }),
  s("fixedupdate", { t({ "void FixedUpdate()", "{", "    " }), i(1), t({ "", "}" }) }),
  s("onenable", { t({ "void OnEnable()", "{", "    " }), i(1), t({ "", "}" }) }),
  s("ondisable", { t({ "void OnDisable()", "{", "    " }), i(1), t({ "", "}" }) }),
  s("ontriggerenter", { t({ "void OnTriggerEnter(Collider other)", "{", "    " }), i(1), t({ "", "}" }) }),
  s("oncollisionenter", { t({ "void OnCollisionEnter(Collision collision)", "{", "    " }), i(1), t({ "", "}" }) }),
  s("serializefield", { t("[SerializeField] private "), i(1, "Type"), t(" "), i(2, "variableName"), t(";") }),
  s("publicfield", { t("public "), i(1, "Type"), t(" "), i(2, "variableName"), t(";") }),
  s("log", { t("Debug.Log(\""), i(1, "message"), t("\");") }),
  s("mono", { d(1, function() return unity_class("MonoBehaviour") end) }),
  s("so", { d(1, function() return unity_class("ScriptableObject") end) }),
}
