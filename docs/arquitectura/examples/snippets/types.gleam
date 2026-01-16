// Extracted reference snippet (v0)
// Source: arquitectura/tipos.md (first code block)
// Purpose: documentation-only; may not compile as-is.

// FILE: saar/types.gleam (dominio + wire; 0 imports OTP)
import gleam/dict.{type Dict}
import gleam/float
import gleam/http.{type Method}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import saar/ffi
import youid/uuid

// Timestamp y FFI centralizada

// ============================================================================
// SECCIÓN 1: IDENTIFICADORES OPACOS
// ============================================================================
// Estos SÍ son opacos porque previenen confusión entre tipos de IDs.
// Un ProfileId nunca puede usarse donde se espera InstanceId.

/// Identificador único de un perfil de agente.
/// Opaco para evitar confusión con otros identificadores string.
pub opaque type ProfileId {
  ProfileId(String)
}

/// Identificador único de una instancia de agente en ejecución.
/// Opaco para evitar confusión con ProfileId o TraceId.
pub opaque type InstanceId {
  InstanceId(String)
}

/// Errores de formato para InstanceId.
pub type InstanceIdError {
  EmptyInstanceId
  InstanceIdTooLong(max: Int)
  InstanceIdInvalidChar(char: String)
}

/// Identificador de traza para correlacionar requests a través del sistema.
/// Opaco para garantizar que siempre se use el tipo correcto en logging/telemetría.
pub opaque type TraceId {
  TraceId(String)
}

// --- Constructores y conversores de IDs ---

pub fn profile_id(s: String) -> ProfileId {
  ProfileId(s)
}

pub fn profile_id_to_string(id: ProfileId) -> String {
  let ProfileId(s) = id
  s
}

/// InstanceId valida formato: [A-Za-z0-9_-], longitud 1..64.
pub fn instance_id(s: String) -> Result(InstanceId, InstanceIdError) {
  case string.is_empty(s) {
    True -> Error(EmptyInstanceId)
    False ->
      case string.length(s) > 64 {
        True -> Error(InstanceIdTooLong(max: 64))
        False ->
          case
            s
            |> string.to_graphemes
            |> list.find(fn(char) { is_instance_id_char(char) == False })
          {
            Ok(char) -> Error(InstanceIdInvalidChar(char))
            Error(_) -> Ok(InstanceId(s))
          }
      }
  }
}

pub fn instance_id_to_string(id: InstanceId) -> String {
  let InstanceId(s) = id
  s
}

pub fn trace_id(s: String) -> TraceId {
  TraceId(s)
}

pub fn trace_id_to_string(id: TraceId) -> String {
  let TraceId(s) = id
  s
}

fn is_instance_id_char(char: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_",
    char,
  )
}

// ============================================================================
// SECCIÓN 2: VALORES TIPADOS (UNIFICADO)
// ============================================================================
// Un solo tipo Value para configuración e inputs.
// La restricción "ConfigValue no tiene listas" se valida en el decoder.

/// Valor tipado para configuración e inputs.
/// Unifica lo que antes eran ConfigValue e InputValue separados.
/// 
/// - Para parámetros de perfil (ConfigValue): solo escalares (String/Int/Float/Bool)
/// - Para extra_params en payloads (InputValue): escalares + ListVal
/// 
/// La restricción se aplica en el decoder, no en el tipo.
pub type Value {
  StringVal(String)
  IntVal(Int)
  FloatVal(Float)
  BoolVal(Bool)
  /// Solo válido en contexto de InputValue (extra_params).
  /// El decoder de ConfigValue rechaza este variante.
  ListVal(List(String))
}

/// Alias semántico para valores de configuración.
/// En runtime es el mismo tipo Value, pero el decoder rechaza ListVal.
pub type ConfigValue =
  Value

/// Alias semántico para valores de input.
/// Acepta todos los variantes de Value incluyendo ListVal.
pub type InputValue =
  Value

/// Tipo declarado de un parámetro. Usado para validación cruzada en el decoder.
pub type ValueType {
  TypeString
  TypeInt
  TypeFloat
  TypeBool
  TypeList
}

/// Convierte Value a string para serialización wire (env vars, JSON).
pub fn value_to_string(value: Value) -> String {
  case value {
    StringVal(s) -> s
    IntVal(i) -> int.to_string(i)
    FloatVal(f) -> float.to_string(f)
    BoolVal(True) -> "true"
    BoolVal(False) -> "false"
    ListVal(items) -> string.join(items, ",")
  }
}

/// Extrae el tipo de un Value.
pub fn value_type(value: Value) -> ValueType {
  case value {
    StringVal(_) -> TypeString
    IntVal(_) -> TypeInt
    FloatVal(_) -> TypeFloat
    BoolVal(_) -> TypeBool
    ListVal(_) -> TypeList
  }
}

/// Verifica si un Value es escalar (no lista).
pub fn is_scalar(value: Value) -> Bool {
  case value {
    ListVal(_) -> False
    _ -> True
  }
}

// --- SECRETOS ---

/// Valor secreto (API keys, tokens, passwords).
/// Opaco para prevenir que se loguee/serialice accidentalmente.
/// 
/// INVARIANTES:
/// - El valor interno NUNCA se expone en logs, errores o serialización
/// - Solo se puede obtener el valor con secret_to_env_value() para inyectar en env vars
/// - inspect/debug siempre muestra "***REDACTED***"
pub opaque type SecretValue {
  SecretValue(inner: String)
}

/// Crea un SecretValue desde un string.
/// Usado al leer de variables de entorno.
pub fn secret_value(s: String) -> SecretValue {
  SecretValue(s)
}

/// Obtiene el valor interno para inyectar en variables de entorno.
/// ADVERTENCIA: Solo usar para pasar a env vars del runner, NUNCA para logs.
pub fn secret_to_env_value(secret: SecretValue) -> String {
  let SecretValue(inner) = secret
  inner
}

/// Representación segura para logs/debug.
/// Siempre devuelve "***REDACTED***".
pub fn secret_inspect(_secret: SecretValue) -> String {
  "***REDACTED***"
}

/// Verifica si un secreto está vacío (para validación).
pub fn secret_is_empty(secret: SecretValue) -> Bool {
  let SecretValue(inner) = secret
  string.is_empty(inner)
}

// ============================================================================
// SECCIÓN 3: DEFINICIÓN DE PERFIL (MODELO ESTÁTICO)
// ============================================================================
// Tipos TRANSPARENTES porque son "bolsas de datos" sin invariantes.
// La validación ocurre en el decoder, no en constructores.

/// Perfil completo de un agente. Define su identidad, parámetros,
/// cómo ejecutarlo (runner) y cómo interactuar con él (interface).
/// Transparente: no tiene invariantes internos, solo estructura.
pub type Profile {
  Profile(
    meta: ProfileMeta,
    parameters: Dict(String, Parameter),
    runner: Runner,
    interface: Interface,
  )
}

/// Metadatos básicos del perfil: identificación y ciclo de vida.
pub type ProfileMeta {
  ProfileMeta(
    id: ProfileId,
    /// Display name. Si None, usar id.
    name: Option(String),
    lifecycle: Lifecycle,
    description: String,
  )
}

/// Ciclo de vida del agente.
/// - Transient: proceso efímero por interacción (CLI tools)
/// - Continuous: servidor persistente (APIs HTTP)
pub type Lifecycle {
  Transient
  Continuous
}

/// Convierte Lifecycle a string para serialización.
pub fn lifecycle_to_string(lc: Lifecycle) -> String {
  case lc {
    Transient -> "transient"
    Continuous -> "continuous"
  }
}

/// Parsea string a Lifecycle.
pub fn lifecycle_from_string(s: String) -> Result(Lifecycle, String) {
  case s {
    "transient" -> Ok(Transient)
    "continuous" -> Ok(Continuous)
    other ->
      Error(
        "Unknown lifecycle: '" <> other <> "'. Valid: transient, continuous",
      )
  }
}

// --- PARÁMETROS ---

/// Definición de un parámetro del perfil.
/// Transparente porque la validación (ej: secret sin default) ocurre en el decoder.
/// 
/// La resolución de estos parámetros ocurre en `saar/params.gleam`, no aquí.
/// El actor nunca ve Parameter; solo ve ResolvedParams.
pub type Parameter {
  /// Valor fijo embebido en el perfil. No requiere resolución externa.
  FixedParam(value: ConfigValue)

  /// Referencia a config.toml. Se resuelve en params.resolve().
  ConfigParam(
    key: String,
    default: Option(ConfigValue),
    expected_type: ParamType,
  )

  /// Referencia a secreto (variable de entorno). NUNCA tiene default.
  /// El decoder rechaza secrets con default.
  /// `expected_type` indica cómo validar el string del env var.
  SecretParam(key: String, expected_type: ParamType)

  /// Proporcionado al crear la instancia. Puede tener default.
  InitParam(key: String, default: Option(ConfigValue), expected_type: ParamType)
}

/// Tipo declarado de un parámetro en el perfil JSON.
/// Subconjunto de ValueType (sin TypeList, que no es válido para config).
pub type ParamType {
  ParamString
  ParamInt
  ParamFloat
  ParamBool
}

/// Convierte ParamType a ValueType para comparación.
pub fn param_type_to_value_type(pt: ParamType) -> ValueType {
  case pt {
    ParamString -> TypeString
    ParamInt -> TypeInt
    ParamFloat -> TypeFloat
    ParamBool -> TypeBool
  }
}

// --- RUNNER ---

/// Configuración del runner que ejecuta el agente.
/// Define qué herramienta usar, cómo configurar red, env vars y argumentos.
pub type Runner {
  Runner(
    /// Tipo de runner (debe existir en config.toml [runners])
    type_: String,
    /// Configuración para runners genéricos (uvx)
    tool_config: ToolConfig,
    /// Configuración de red (puertos, modo).
    /// Si ausente en JSON, el decoder usa default: NoNetwork sin env vars.
    runtime: RuntimeConfig,
    /// Variables de entorno con templates {{params.*}}, {{helpers.*}}
    env_map: Dict(String, String),
    /// Argumentos CLI con templates
    args: List(String),
    /// Patrones para recolectar artefactos de salida.
    /// Si ausente en JSON, el decoder usa default: sin includes/excludes.
    artifact_config: ArtifactConfig,
  )
}

/// Configuración específica para runners genéricos (generic_uvx, generic_uvx_server).
/// Permite definir agentes puramente declarativos sin scripts custom.
pub type ToolConfig {
  ToolConfig(
    /// Paquete Python a instalar/ejecutar (ej: "aider-chat")
    package: String,
    /// Comando a ejecutar del paquete (ej: "aider")
    command: String,
    /// Dependencias adicionales para --with (ej: ["pip", "fastapi"])
    with_packages: List(String),
  )
}

/// Configuración de red para el runner.
pub type RuntimeConfig {
  RuntimeConfig(
    /// Modo de asignación de puerto
    mode: NetworkMode,
    /// Variable de entorno donde inyectar el puerto (ej: "PORT")
    port_env_var: Option(String),
    /// Variable de entorno donde inyectar el host (ej: "HOST")
    host_env_var: Option(String),
  )
}

/// Default para agentes transient (CLI sin red).
pub fn default_runtime_config() -> RuntimeConfig {
  RuntimeConfig(NoNetwork, None, None)
}

/// Modo de red del runner.
/// Sin fallback UnknownMode: el decoder falla ante valores desconocidos.
///
/// `ManagedPort` usa el port pool de SAAR: reserva un puerto libre en el rango configurado
/// (`SaarConfig.port_range_min/max`, con defaults) y lo inyecta en el runner via env vars.
pub type NetworkMode {
  /// SAAR asigna un puerto del pool configurado
  ManagedPort
  /// El runner no necesita red (CLI puro)
  NoNetwork
}

/// Convierte string a NetworkMode. Falla explícitamente ante valores desconocidos.
pub fn network_mode_from_string(s: String) -> Result(NetworkMode, String) {
  case s {
    "managed_port" -> Ok(ManagedPort)
    "no_network" -> Ok(NoNetwork)
    other ->
      Error(
        "Unknown network mode: '"
        <> other
        <> "'. Valid: managed_port, no_network",
      )
  }
}

pub fn network_mode_to_string(mode: NetworkMode) -> String {
  case mode {
    ManagedPort -> "managed_port"
    NoNetwork -> "no_network"
  }
}

/// Patrones glob para recolectar artefactos del workspace.
pub type ArtifactConfig {
  ArtifactConfig(
    /// Patrones a incluir (ej: ["**/*.pdf", "output/*"])
    include: List(String),
    /// Patrones a excluir (ej: ["*.tmp", ".git/**"])
    exclude: List(String),
  )
}

/// Default: no recolectar artefactos automáticamente.
pub fn default_artifact_config() -> ArtifactConfig {
  ArtifactConfig([], [])
}

// --- STREAMING (v0) ---

/// Configuración del stream de logs (SSE de instancia).
///
/// v0: logs son best-effort (drop/coalesce permitido) y se protegen con:
/// - ring buffer (`SaarConfig.log_buffer_bytes`) en memoria,
/// - batching (para no saturar el socket),
/// - y ausencia de buffers infinitos.
pub type LogStreamConfig {
  LogStreamConfig(
    /// Tamaño ideal del batch (bytes, aproximado sobre el payload de log).
    batch_byte_size: Int,
    /// Tiempo máximo de espera antes de enviar lo que haya (ms).
    flush_interval_ms: Int,
  )
}

/// Configuración del stream de interacción (SSE por request).
///
/// v0: el backpressure real lo impone el `saar/streams/sink.StreamSink` vía ack (call).
/// El worker solo bufferiza hasta `batch_byte_size` (y flushea por tamaño/intervalo).
pub type InteractionStreamConfig {
  InteractionStreamConfig(
    /// Tamaño ideal del batch (bytes, aproximado sobre el payload de chunks).
    batch_byte_size: Int,
    /// Tiempo máximo de espera antes de enviar lo que haya (ms).
    flush_interval_ms: Int,
    /// Tiempo máximo que el producer espera a que el `StreamSink` acepte/escriba (ms).
    /// Si expira o el cliente se desconecta, SAAR corta el streaming (discard) y continúa hasta `InteractionDone`.
    /// Recomendación v0: mantenerlo pequeño (p.ej. 100–500ms) para detectar SSE lento/disconnect y degradar rápido.
    push_timeout_ms: Int,
  )
}

// --- INTERFACE ---

/// Interfaz de comunicación con el agente.
/// Split en dos variantes porque tienen campos incompatibles:
/// - HTTP requiere base_url, health_check
/// - Runner no los tiene
pub type Interface {
  /// Interfaz HTTP para agentes continuous (servidores)
  HttpInterface(
    /// URL base del servidor (ej: "http://{{runner.host}}:{{runner.port}}")
    base_url: String,
    /// Headers HTTP con templates
    headers: Dict(String, String),
    /// Configuración de health check
    health_check: Option(HealthCheck),
    /// Capabilities expuestas vía HTTP
    capabilities: Dict(String, HttpCapability),
  )
  /// Interfaz directa para agentes transient (CLI)
  RunnerInterface(
    /// Capabilities que el runner maneja directamente
    capabilities: Dict(String, RunnerCapability),
  )
}

/// Configuración de health check para servidores continuous.
pub type HealthCheck {
  HealthCheck(
    /// Path del endpoint (ej: "/health")
    path: String,
    /// Método HTTP (típicamente Get). Usa gleam/http.Method.
    method: Method,
    /// Códigos de estado que indican salud (ej: [200, 204])
    expect_statuses: List(Int),
  )
}

/// Límites configurables por capability.
/// Permite sobrescribir defaults de SaarConfig para operaciones específicas.
pub type CapabilityLimits {
  CapabilityLimits(
    /// Timeout para esta capability (sobrescribe config.call_timeout_ms)
    call_timeout_ms: Option(Int),
  )
}

// --- HTTP request body (JSON / multipart) ---

/// En capabilities HTTP, SAAR puede construir el request body en dos modos:
/// - JSON: template Json con inserciones `$from` (JSON Pointer) + strings con `{{...}}` (strict).
/// - Multipart: form fields (strings interpoladas) + file parts (tomados del input).
pub type HttpRequestBody {
  JsonBody(template: Json)
  MultipartBody(spec: MultipartBodySpec)
}

/// Especificación de multipart/form-data.
pub type MultipartBodySpec {
  MultipartBodySpec(
    /// Campos de formulario como strings (se interpolan strict con `{{namespace.key}}`).
    fields: Dict(String, String),
    /// Archivos adjuntos (tomados del input de la interacción).
    files: List(MultipartFilePart),
  )
}

/// Parte de archivo en multipart.
pub type MultipartFilePart {
  MultipartFilePart(
    /// Nombre del campo (ej: "file")
    field: String,
    /// De dónde tomar el archivo (v0: puntero a `SAAR_INPUT_JSON`).
    source_pointer: String,
  )
}

/// Capability expuesta vía HTTP (para agentes continuous).
pub type HttpCapability {
  HttpCapability(
    /// Path del endpoint (ej: "/query")
    path: String,
    /// Método HTTP (ej: Post). Usa gleam/http.Method.
    method: Method,
    /// Schema de validación del input
    input_schema: Option(InputSchema),
    /// Body del request HTTP (JSON o multipart).
    /// La interpolación/resolución ocurre en el bridge antes de enviar.
    body: Option(HttpRequestBody),
    /// Mapeo de la respuesta del runner al formato de salida
    response: Option(ResponseMapping),
    /// Descripción human-readable
    description: Option(String),
    /// Hint para renderizado en UI (Json libre, interpretado por frontend)
    ui_hint: Option(Json),
    /// Si true, SAAR puede emitir eventos de streaming y el gateway abre SSE.
    /// En HTTP (continuous), el agente debe exponer una respuesta SSE con este contrato v0:
    /// - El request usa el mismo método + headers + body definido por la capability.
    ///   Para chat streaming lo normal es `POST` con body JSON y respuesta `text/event-stream`.
    ///   Si el método es `GET`, el body debe ser `None`.
    /// - Cada evento SSE incluye `data: <json>` donde `<json>` es **un objeto** con la misma forma
    ///   que el contrato de runners (`t="log"|"chunk"|"result"`).
    /// - El stream termina cuando SAAR recibe `t="result"` (y el agente debe cerrar la conexión).
    /// - Si la conexión se cierra sin `t="result"`, SAAR trata la interacción como `InfraError`.
    /// - Se aplican los mismos límites por línea/evento que en runners (ver `protocolos_runner.md`).
    /// Default: False
    streaming: Bool,
    /// Límites específicos para esta capability
    limits: Option(CapabilityLimits),
  )
}

/// Capability manejada directamente por el runner (para agentes transient).
pub type RunnerCapability {
  RunnerCapability(
    /// Schema de validación del input
    input_schema: Option(InputSchema),
    /// Descripción human-readable
    description: Option(String),
    /// Hint para renderizado en UI (Json libre, interpretado por frontend)
    ui_hint: Option(Json),
    /// Si true, el runner emite chunks de streaming y el gateway abre SSE.
    /// Contrato (v0, BEAM/OTP-friendly):
    /// - SAAR consume un único canal capturado por `open_port` (STDOUT del wrapper/runner).
    /// - El runner emite eventos JSONL (1 JSON por línea) con `t`:
    ///   - `t="log"` (opcional) para logs,
    ///   - `t="chunk"` (opcional; si streaming=true) para deltas incrementales,
    ///   - `t="result"` (obligatorio; exactamente uno) con forma `RunnerResponse`.
    /// - STDERR está fuera de contrato (diagnóstico local); SAAR no depende de capturarlo.
    /// Default: False
    streaming: Bool,
    /// Límites específicos para esta capability
    limits: Option(CapabilityLimits),
  )
}

/// Schema de validación del input.
/// Conjunto cerrado y autodescriptivo. El frontend puede generar UI
/// dinámica a partir de cualquier variante. Fail-fast ante schemas desconocidos.
///
/// Wire format en perfiles JSON (3 formas equivalentes):
/// 1. String shorthand: `"std:chat"` o `"std:files"` (más simple)
/// 2. Objeto con $ref: `{"$ref": "std:chat"}` (más explícito)
/// 3. Objeto extended: `{"base": "std:chat", "extra_fields": {...}}`
///
/// El decoder acepta las 3 formas y las normaliza al ADT interno.
///
/// No existe variante "opaca": todos los schemas deben ser interpretables
/// por el frontend para cumplir el principio de autodescripción (ver `arquitectura/README.md`).
pub type InputSchema {
  /// std:chat - conversaciones con mensajes
  /// Wire: "std:chat" | {"$ref": "std:chat"}
  SchemaChat
  /// std:files - procesamiento de archivos
  /// Wire: "std:files" | {"$ref": "std:files"}
  SchemaFiles
  /// std:chat + campos extra tipados
  /// Wire: {"base": "std:chat", "extra_fields": {...}}
  /// extra_fields contiene metadata para que el frontend genere formularios
  SchemaChatExtended(extra_fields: Dict(String, ExtraFieldDef))
}

/// Definición de un campo extra en SchemaChatExtended.
/// Metadata suficiente para validación y generación de UI.
pub type ExtraFieldDef {
  ExtraFieldDef(
    /// Tipo del campo
    type_: ExtraFieldType,
    /// Valores permitidos (solo para strings)
    enum_values: Option(List(String)),
    /// Valor por defecto si no se proporciona
    default: Option(Value),
  )
}

/// Tipos soportados para extra_fields.
/// Sin fallback: el decoder falla ante tipos desconocidos.
pub type ExtraFieldType {
  FieldString
  FieldBoolean
  FieldNumber
  FieldInteger
}

// BodyTemplate (HTTP) vive dentro de HttpRequestBody.JsonBody.
// Permite `{{namespace.key}}` (strict, escalares) y `{"$from": "/pointer"}` para inyectar valores estructurados.

/// Mapeo de la respuesta del runner al formato de salida.
/// Usa JSON Pointers para extraer campos.
pub type ResponseMapping {
  ResponseMapping(
    /// JSON Pointer al texto de respuesta (ej: "/answer")
    text_pointer: Option(String),
    /// JSON Pointer a la lista de artefactos (ej: "/attachments")
    artifacts_pointer: Option(String),
  )
}

// UiHint eliminado: usar Option(Json) directamente en HttpCapability/RunnerCapability.
//
// SAAR es solo mensajero de hints; no los interpreta ni valida su estructura.
// El frontend es responsable de:
// 1. Interpretar el JSON según el campo "kind" (web_component, ag-ui, etc.)
// 2. Implementar fallback para hints desconocidos (formulario genérico)
//
// Ejemplos de hints válidos:
//
// Web Component:
// {"kind": "web_component", "tag": "vanna-chat", "script_src": "...", "props_template": {...}}
//
// AG-UI:
// {"kind": "ag-ui", "entrypoint": "/agents/{{instance_id}}/ui/agui", "protocol": "sse"}
//
// Nota: mantener el contrato de `ui_hint` minimalista; SAAR no lo interpreta.

// ============================================================================
// SECCIÓN 4: PAYLOAD DE ENTRADA (TIPADO)
// ============================================================================
// Representa el input de una interacción. Tipado internamente,
// se convierte a/desde Dynamic solo en las fronteras.

/// Payload de entrada para una interacción.
/// ADT que elimina Dynamic del modelo interno.
/// Correspondencia con InputSchema:
///   SchemaChat / SchemaChatExtended → PayloadChat
///   SchemaFiles                     → PayloadFiles
///   (mensajes + archivos juntos)    → PayloadMixed
///
/// Todas las variantes son autodescriptivas: el frontend puede validar
/// y generar UI para cualquiera de ellas.
pub type InputPayload {
  /// Conversación con historial de mensajes (std:chat y chat extendido)
  PayloadChat(
    messages: List(ChatMessage),
    /// Parámetros extra mezclados en la raíz al serializar.
    /// Vacío para SchemaChat puro; poblado para SchemaChatExtended.
    /// Usa InputValue (alias de Value) que acepta ListVal.
    extra_params: Dict(String, InputValue),
  )
  /// Lista de archivos a procesar (std:files)
  /// Sin extra_params: los agentes de archivos reciben solo la lista de files.
  PayloadFiles(files: List(FileRef))
  /// Mensajes + archivos juntos (ej: "Analiza este PDF" + archivo adjunto)
  /// Común en protocolos como A2A donde un mensaje puede tener TextPart + FilePart.
  PayloadMixed(
    messages: List(ChatMessage),
    files: List(FileRef),
    extra_params: Dict(String, InputValue),
  )
}

/// Mensaje en una conversación.
pub type ChatMessage {
  ChatMessage(
    /// Rol del emisor. String para extensibilidad (user, assistant, system, tool, developer...)
    role: String,
    /// Contenido textual del mensaje
    content: String,
  )
}

/// Referencia a un archivo para procesamiento.
pub type FileRef {
  FileRef(
    /// URL accesible por el runner.
    /// Puede ser externa (S3/GCS/HTTP) o interna del despliegue (URL pre-firmada, proxy, etc.).
    /// SAAR v0 no transporta bytes inline en protocolos (p.ej. A2A `file.bytes`).
    url: String,
    /// Tipo MIME del archivo
    mime: String,
    /// Nombre del archivo
    name: String,
    /// Contexto/instrucciones sobre qué hacer con el archivo
    context: Option(String),
  )
}

/// Helpers derivados automáticamente del InputPayload.
/// Se calculan bajo demanda para interpolación, no se almacenan.
pub type SadHelpers {
  SadHelpers(
    /// Contenido del último mensaje con role="user"
    last_user_content: Option(String),
    /// Lista de archivos del último input
    last_user_files: List(FileRef),
  )
}

/// Deriva helpers desde un InputPayload.
/// Todas las variantes tienen helpers derivables (principio de autodescripción).
pub fn derive_helpers(payload: InputPayload) -> SadHelpers {
  case payload {
    PayloadChat(messages, _) -> {
      let last_user_content =
        messages
        |> list.reverse
        |> list.find(fn(m) { m.role == "user" })
        |> option.map(fn(m) { m.content })
      SadHelpers(last_user_content: last_user_content, last_user_files: [])
    }
    PayloadFiles(files) -> {
      SadHelpers(last_user_content: None, last_user_files: files)
    }
    PayloadMixed(messages, files, _) -> {
      // Mixed: combina ambos - último mensaje de usuario + todos los archivos
      let last_user_content =
        messages
        |> list.reverse
        |> list.find(fn(m) { m.role == "user" })
        |> option.map(fn(m) { m.content })
      SadHelpers(last_user_content: last_user_content, last_user_files: files)
    }
  }
}

// ============================================================================
// SECCIÓN 5: CONTEXTO DE REQUEST
// ============================================================================

/// Contexto de una request (modelo interno).
/// trace_id siempre presente (el gateway lo genera si falta en wire).
/// 
/// SAAR es stateless puro: no maneja conceptos de tenant ni user.
pub type RequestContext {
  RequestContext(
    trace_id: TraceId,
    /// Metadatos extra (extensibilidad)
    extra: Dict(String, String),
  )
}

// ============================================================================
// SECCIÓN 6: CONTRATO RUNNER (SAAR ↔ SCRIPTS)
// ============================================================================
// Los tipos del contrato runner están en saar/bridge/runner_contract.gleam
// Ver `arquitectura/protocolos_runner.md` para documentación completa.
//
// Importar como:
//   import saar/bridge/runner_contract.{
//     type SaarInput, type RunnerResponse, type ArtifactRef,
//     validate_response, saar_input_to_json,
//   }
//
// El módulo runner_contract.gleam es PURO (sin IO).
// ============================================================================
// Solo tipos internos. La serialización a JSON se hace con funciones
// en el módulo bridge/serialization.gleam, no con tipos Wire separados.

/// Input completo enviado al runner vía STDIN.
/// Modelo interno rico. Se serializa a JSON con saar_input_to_json().
pub type SaarInput {
  SaarInput(
    meta: SaarInputMeta,
    /// Parámetros resueltos (incluye secretos como SecretVal).
    /// Producido por params.resolve(), nunca por el actor.
    /// NOTA: Al serializar a JSON, los secretos se incluyen (van al runner).
    params: ResolvedParams,
    /// Payload de la interacción
    input: InputPayload,
    /// Contexto de trazabilidad
    context: RequestContext,
    /// Helpers derivados (solo para schemas estándar)
    helpers: Option(SadHelpers),
    /// Definición del runner (para runners genéricos)
    runner_def: Runner,
  )
}

/// Metadatos del input para el runner.
/// Se serializa a JSON con saar_input_meta_to_json().
pub type SaarInputMeta {
  SaarInputMeta(
    spec_version: String,
    profile_id: ProfileId,
    /// None en transient puro sin instancia persistente
    instance_id: Option(InstanceId),
    mode: Lifecycle,
  )
}

/// Respuesta del runner (recibida vía evento `t="result"`).
pub type RunnerResponse {
  RunnerResponse(
    status: RunnerStatus,
    /// Datos de respuesta (estructura variable según capability)
    data: Option(Json),
    /// Artefactos generados
    artifacts: List(ArtifactRef),
    /// Error si status=error
    error: Option(RunnerError),
  )
}

/// Estado de la respuesta del runner.
pub type RunnerStatus {
  StatusSuccess
  StatusError
}

/// Referencia a un artefacto generado por el runner.
/// El path debe estar dentro del workspace (validado por WorkspacePath).
pub type ArtifactRef {
  ArtifactRef(
    name: String,
    /// Path validado dentro del workspace
    path: WorkspacePath,
    mime: String,
  )
}

// --- WORKSPACE PATH (SEGURIDAD) ---

/// Path seguro dentro del workspace.
/// Opaco porque tiene invariantes de seguridad:
/// - No contiene segmentos `..` (path traversal)
/// - No contiene null bytes
/// - Es relativo (no absoluto)
/// - Está normalizado
/// 
/// Solo puede construirse via validate().
pub opaque type WorkspacePath {
  WorkspacePath(String)
}

/// Errores de validación de paths.
pub type PathError {
  /// Path contiene segmentos `..` (intento de traversal)
  PathTraversalDetected(raw: String)
  /// Path resuelto está fuera del workspace (p.ej. por symlinks al acceder al FS)
  PathOutsideWorkspace(raw: String, root: String)
  /// Path vacío
  EmptyPath
  /// Carácter inválido (null byte, etc.)
  InvalidCharacter(raw: String, char: String)
  /// Path absoluto no permitido
  AbsolutePathNotAllowed(raw: String)
}

/// Valida y construye un WorkspacePath seguro.
/// Falla si el path contiene traversal, caracteres inválidos, o está fuera del workspace.
pub fn workspace_path_validate(
  workspace_root: String,
  raw_path: String,
) -> Result(WorkspacePath, PathError) {
  // 1. Rechazar vacío
  case raw_path {
    "" -> Error(EmptyPath)
    _ -> validate_non_empty(workspace_root, raw_path)
  }
}

fn validate_non_empty(
  root: String,
  raw: String,
) -> Result(WorkspacePath, PathError) {
  // 2. Rechazar absolutos
  case string.starts_with(raw, "/") {
    True -> Error(AbsolutePathNotAllowed(raw))
    False -> validate_relative(root, raw)
  }
}

fn validate_relative(
  root: String,
  raw: String,
) -> Result(WorkspacePath, PathError) {
  // 3. Rechazar null bytes
  case string.contains(raw, "\u{0}") {
    True -> Error(InvalidCharacter(raw, "\\0"))
    False -> validate_no_null(root, raw)
  }
}

fn validate_no_null(
  root: String,
  raw: String,
) -> Result(WorkspacePath, PathError) {
  // 4. Normalizar por segmentos y rechazar traversal real (`..` como segmento).
  // Importante: NO usar `string.contains("..")` (falsos positivos: "my..file").
  // Regla: split por "/" y procesar segmentos.
  // Nota: `root` no participa en esta validación sintáctica; se usa al acceder al FS
  // (p.ej. `workspace.read_file`) para mitigar escapes por symlinks.
  use normalized <- result.try(normalize_path(raw))
  case normalized {
    "" -> Error(EmptyPath)
    _ -> Ok(WorkspacePath(normalized))
  }
}

/// Normaliza un path por segmentos:
/// - colapsa múltiples `/`
/// - elimina `.` y segmentos vacíos
/// - rechaza `..` como segmento (path traversal)
fn normalize_path(raw: String) -> Result(String, PathError) {
  raw
  |> string.split("/")
  |> list.fold(Ok([]), fn(acc, seg) {
    use segments <- result.try(acc)
    case seg {
      "" -> Ok(segments)
      "." -> Ok(segments)
      ".." -> Error(PathTraversalDetected(raw))
      other -> Ok([other, ..segments])
    }
  })
  |> result.map(fn(segments) { segments |> list.reverse |> string.join("/") })
}

/// Extrae el string interno de un WorkspacePath validado.
pub fn workspace_path_to_string(path: WorkspacePath) -> String {
  let WorkspacePath(s) = path
  s
}

/// Construye el path absoluto combinando root + WorkspacePath.
pub fn workspace_path_to_absolute(root: String, path: WorkspacePath) -> String {
  root <> "/" <> workspace_path_to_string(path)
}

/// Nota de seguridad (symlinks):
/// `WorkspacePath` evita traversal por segmentos `..`, pero **no** es una sandbox de filesystem.
/// Un runner podría crear symlinks dentro del workspace que apunten fuera del root.
///
/// Por tanto, cualquier acceso a disco basado en `WorkspacePath` (p.ej. servir artefactos)
/// debe aplicar una verificación adicional a nivel de FS:
/// - canonicalizar (`realpath`) `root` y `root/path`, y verificar que el segundo está bajo el primero, y/o
/// - rechazar symlinks (`read_link_info`) en la ruta objetivo (y, idealmente, en sus directorios),
/// y además exigir que el target sea un fichero regular.
/// Genera nombre de directorio para una instancia.
pub fn workspace_dir_name(instance_id: InstanceId) -> String {
  "workspace-" <> instance_id_to_string(instance_id)
}

/// Construye path completo de workspace para una instancia.
pub fn workspace_for_instance(
  base_dir: String,
  instance_id: InstanceId,
) -> String {
  base_dir <> "/" <> workspace_dir_name(instance_id)
}

pub fn path_error_to_string(err: PathError) -> String {
  case err {
    PathTraversalDetected(raw) -> "Path traversal detected: '" <> raw <> "'"
    PathOutsideWorkspace(raw, root) ->
      "Path '" <> raw <> "' resolves outside workspace '" <> root <> "'"
    EmptyPath -> "Path cannot be empty"
    InvalidCharacter(raw, char) ->
      "Path '" <> raw <> "' contains invalid character: " <> char
    AbsolutePathNotAllowed(raw) -> "Absolute path not allowed: '" <> raw <> "'"
  }
}

/// Error reportado por el runner.
/// Se serializa a JSON con runner_error_to_json().
pub type RunnerError {
  RunnerError(kind: ErrorKind, message: String)
}

/// Tipo de error. Sin fallback: el decoder falla ante valores desconocidos.
pub type ErrorKind {
  /// Error de lógica de negocio del agente
  AgentError
  /// Error de infraestructura (red, proceso, timeout)
  InfraError
  /// Input inválido del cliente
  BadRequest
}

pub fn error_kind_from_string(s: String) -> Result(ErrorKind, String) {
  case s {
    "agent_error" -> Ok(AgentError)
    "infra_error" -> Ok(InfraError)
    "bad_request" -> Ok(BadRequest)
    other ->
      Error(
        "Unknown error kind: '"
        <> other
        <> "'. Valid: agent_error, infra_error, bad_request",
      )
  }
}

pub fn error_kind_to_string(kind: ErrorKind) -> String {
  case kind {
    AgentError -> "agent_error"
    InfraError -> "infra_error"
    BadRequest -> "bad_request"
  }
}

// ============================================================================
// SECCIÓN 7: API PÚBLICA (GATEWAY) - WIRE FORMAT
// ============================================================================
// Tipos para la frontera HTTP. Solo mantenemos tipos Wire cuando hay
// diferencia estructural real (inputs opaco vs tipado, opcionalidad diferente).
//
// NOTA: Estos son tipos internos de SAAR. El gateway expone una API compatible
// con el protocolo A2A (ver protocolos.md), pero los tipos aquí son para uso interno.
// La conversión A2A wire ↔ SAAR interno ocurre en el módulo saar/a2a.gleam.

/// Request tal como llega del cliente (wire format interno de SAAR).
/// 
/// NOTA: Este tipo Wire se mantiene porque `inputs` es Json opaco aquí
/// pero InputPayload tipado en AgentInteractionRequest. Diferencia estructural real.
pub type AgentRequestWire {
  AgentRequestWire(
    capability: String,
    /// Input sin parsear (se valida contra input_schema)
    inputs: Json,
    /// Context obligatorio. Si trace_id falta, gateway lo genera.
    context: RequestContextWire,
  )
}

/// Context wire format (todo strings, campos internos opcionales).
/// El cliente DEBE enviar context, pero puede omitir campos individuales.
/// 
/// NOTA: Este tipo Wire se mantiene porque la semántica de opcionalidad
/// es diferente: aquí trace_id es opcional, en RequestContext es obligatorio.
pub type RequestContextWire {
  RequestContextWire(
    /// Si falta, el gateway genera uno automáticamente
    trace_id: Option(String),
    extra: Option(Dict(String, String)),
  )
}

/// Request de interacción normalizada (modelo interno).
/// context siempre presente, trace_id garantizado.
pub type AgentInteractionRequest {
  AgentInteractionRequest(
    capability: String,
    /// Input parseado y validado
    inputs: InputPayload,
    /// Context normalizado con trace_id garantizado
    context: RequestContext,
  )
}

/// Errores de normalización de AgentInteractionRequest.
/// Solo errores de validación real, no de campos faltantes que se pueden generar.
pub type AgentRequestError {
  InvalidInputPayload(String)
  UnknownCapability(String)
}

pub fn agent_request_error_to_string(err: AgentRequestError) -> String {
  case err {
    InvalidInputPayload(msg) -> "Invalid input: " <> msg
    UnknownCapability(cap) -> "Unknown capability: " <> cap
  }
}

// --- RESPONSE ---

/// Resultado interno de una interacción (modelo de dominio).
/// El gateway serializa este resultado a JSON para el cliente (y usa RFC7807 para errores).
pub type InteractionResult {
  InteractionResult(
    /// Datos de respuesta
    data: ResponseData,
    /// Artefactos generados (con URLs públicas)
    artifacts: List(PublicArtifact),
    /// Trace para correlación
    trace_id: TraceId,
  )
}

/// Datos de respuesta de una interacción exitosa.
pub type ResponseData {
  ResponseData(
    /// Texto principal de respuesta
    content: Option(String),
    /// Metadatos adicionales (usage, etc.)
    metadata: Dict(String, Json),
  )
}

/// Artefacto con URL pública (para el cliente).
pub type PublicArtifact {
  PublicArtifact(
    name: String,
    /// URL pública para descargar (ej: /artifacts/abc123)
    url: String,
    mime: String,
  )
}

/// Error de interacción (modelo interno).
pub type InteractionError {
  InteractionError(kind: ErrorKind, message: String, trace_id: TraceId)
}

// --- SERIALIZACIÓN DE RESPONSES ---
// No hay un tipo "wire" separado para respuestas: el gateway serializa directamente a JSON
// (éxito) o a Problem Details RFC7807 (error) usando funciones.

/// Serializa InteractionResult a JSON para respuesta HTTP.
/// Formato: {"status": "success", "data": {...}, "artifacts": [...], "trace_id": "..."}
pub fn interaction_result_to_json(result: InteractionResult) -> Json {
  json.object([
    #("status", json.string("success")),
    #("data", response_data_to_json(result.data)),
    #("artifacts", json.array(result.artifacts, public_artifact_to_json)),
    #("trace_id", json.string(trace_id_to_string(result.trace_id))),
  ])
}

/// Serializa InteractionError como RFC 7807 (Problem Details).
/// En SAAR v0, *errores* HTTP (nativo y A2A) usan RFC 7807; el formato
/// `{"status":"error", ...}` no se usa ya para respuestas HTTP.
///
/// Campos mínimos:
/// - type/status/title/detail/instance
/// - extensions.kind (snake_case) y extensions.trace_id
///
/// Tabla canónica de mapeo: ver `protocolos.md` §0.1.
pub fn interaction_error_to_problem_details(
  err: InteractionError,
  instance: String,
) -> Json {
  let kind = error_kind_to_string(err.kind)
  let #(status, type_url, title) = case err.kind {
    BadRequest -> #(400, "https://saar/errors/invalid-request", "Bad Request")
    AgentError -> #(
      422,
      "https://saar/errors/upstream-error",
      "Unprocessable Entity",
    )
    InfraError -> #(
      500,
      "https://saar/errors/infra-error",
      "Internal Server Error",
    )
  }

  json.object([
    #("type", json.string(type_url)),
    #("status", json.int(status)),
    #("title", json.string(title)),
    #("detail", json.string(err.message)),
    #("instance", json.string(instance)),
    #(
      "extensions",
      json.object([
        #("kind", json.string(kind)),
        #("trace_id", json.string(trace_id_to_string(err.trace_id))),
      ]),
    ),
  ])
}

/// Serializa ResponseData a JSON.
fn response_data_to_json(data: ResponseData) -> Json {
  let content_field = case data.content {
    Some(c) -> [#("content", json.string(c))]
    None -> []
  }
  let metadata_fields =
    data.metadata
    |> dict.to_list
    |> list.map(fn(pair) { #(pair.0, pair.1) })

  json.object(list.append(content_field, metadata_fields))
}

/// Serializa PublicArtifact a JSON.
fn public_artifact_to_json(artifact: PublicArtifact) -> Json {
  json.object([
    #("name", json.string(artifact.name)),
    #("url", json.string(artifact.url)),
    #("mime", json.string(artifact.mime)),
  ])
}

/// Convierte RunnerError a JSON (para logs/debugging).
pub fn runner_error_to_json(err: RunnerError) -> Json {
  json.object([
    #("kind", json.string(error_kind_to_string(err.kind))),
    #("message", json.string(err.message)),
  ])
}

// ============================================================================
// SECCIÓN 8: ESTADO DE RUNTIME (ACTORES)
// ============================================================================

/// Valor resuelto de un parámetro.
/// Distingue entre valores normales y secretos para prevenir logs accidentales.
pub type ResolvedValue {
  /// Valor normal (config, fixed, init) - se puede loguear
  NormalValue(ConfigValue)
  /// Secreto (de env var) - NUNCA loguear
  SecretVal(SecretValue)
}

/// Parámetros resueltos listos para usar.
/// 
/// Producido por `saar/params.resolve()`, consumido por AgentActor.
/// El actor nunca ve Parameter; solo ve este tipo ya resuelto.
/// 
/// IMPORTANTE: Usar `resolved_value_to_env()` para convertir a string.
/// Nunca iterar y loguear valores directamente.
pub type ResolvedParams =
  Dict(String, ResolvedValue)

/// Convierte un ResolvedValue a string para env vars del runner.
/// Seguro para todos los tipos (secretos incluidos, ya que van a env).
pub fn resolved_value_to_env(value: ResolvedValue) -> String {
  case value {
    NormalValue(v) -> value_to_string(v)
    SecretVal(s) -> secret_to_env_value(s)
  }
}

/// Representación segura para logs/debug.
/// Los secretos se muestran como "***REDACTED***".
pub fn resolved_value_inspect(value: ResolvedValue) -> String {
  case value {
    NormalValue(v) -> value_to_string(v)
    SecretVal(_) -> "***REDACTED***"
  }
}

/// Errores posibles durante la resolución de parámetros.
/// Definido aquí para que sea accesible desde cualquier módulo.
/// La lógica de resolución está en `saar/params.gleam`.
pub type ParamResolutionError {
  /// Clave no encontrada en config.toml y sin default
  MissingConfig(param_name: String, config_key: String)
  /// Variable de entorno no definida (secrets nunca tienen default)
  MissingSecret(param_name: String, env_key: String)
  /// Parámetro de inicialización no proporcionado y sin default
  MissingInitParam(param_name: String, init_key: String)
  /// Secret presente pero no parseable al tipo esperado
  SecretParseError(
    param_name: String,
    env_key: String,
    expected: ValueType,
    got: String,
  )
  /// Tipo del valor no coincide con el declarado
  TypeMismatch(param_name: String, expected: ValueType, got: ValueType)
}

/// Convierte error de resolución a mensaje legible.
pub fn param_resolution_error_to_string(err: ParamResolutionError) -> String {
  case err {
    MissingConfig(param, key) ->
      "Parameter '"
      <> param
      <> "' requires config key '"
      <> key
      <> "' which is not defined and has no default"
    MissingSecret(param, key) ->
      "Parameter '"
      <> param
      <> "' requires environment variable '"
      <> key
      <> "' which is not set"
    MissingInitParam(param, key) ->
      "Parameter '"
      <> param
      <> "' requires init param '"
      <> key
      <> "' which was not provided and has no default"
    SecretParseError(param, key, expected, got) ->
      "Parameter '"
      <> param
      <> "' from env var '"
      <> key
      <> "' expected "
      <> value_type_to_string(expected)
      <> " but got: '"
      <> got
      <> "'"
    TypeMismatch(param, expected, got) ->
      "Parameter '"
      <> param
      <> "' expected "
      <> value_type_to_string(expected)
      <> " but got "
      <> value_type_to_string(got)
  }
}

/// Convierte ValueType a string para mensajes de error.
pub fn value_type_to_string(vt: ValueType) -> String {
  case vt {
    TypeString -> "string"
    TypeInt -> "int"
    TypeFloat -> "float"
    TypeBool -> "bool"
    TypeList -> "list"
  }
}

// ============================================================================
// SECCIÓN: VISTA DE ESTADO (WIRE/DIAGNÓSTICO; sin secretos ni recursos)
// ============================================================================
// Ubicación: `saar/types.gleam`
//
// Nota: el estado runtime del actor incluye `ResolvedParams` y recursos BEAM (Port), por lo que
// no es serializable ni seguro de exponer. El gateway solo serializa estos tipos "view".

/// Fase publicable de una instancia (wire/diagnóstico).
pub type AgentPhase {
  Created
  Provisioning
  ReadyTransient
  ReadyContinuous
  Stopped
  Failed
}

/// Modo publicable (sin detalles internos como InFlight, reply subjects, etc.).
pub type AgentRunMode {
  RunIdle
  RunBusy
}

/// Vista serializable del estado de una instancia.
/// - No incluye `ResolvedParams` ni `AgentResource`.
/// - No incluye secretos ni handles OTP.
pub type AgentStatusView {
  AgentStatusView(
    profile_id: ProfileId,
    instance_id: InstanceId,
    lifecycle: Lifecycle,
    phase: AgentPhase,
    mode: AgentRunMode,
    assigned_port: Option(Int),
    failure_reason: Option(String),
  )
}

/// Resumen cacheado de una instancia (para listados).
pub type InstanceSummary {
  InstanceSummary(
    status: AgentStatusView,
    registered_at: Int,
    status_updated_at: Int,
  )
}

/// Info pública de una instancia para listados/diagnóstico.
pub type AgentInfoView {
  AgentInfoView(
    meta: ProfileMeta,
    runner: Runner,
    interface: Interface,
    status: AgentStatusView,
  )
}

// ============================================================================
// FILE: saar/core/agent.gleam (estado runtime; puede usar tipos OTP como Port)
// ============================================================================
import gleam/erlang/port.{type Port}

/// Recurso del sistema asociado a un agente continuous.
/// Opaco porque encapsula recursos de bajo nivel (Port).
pub opaque type AgentResource {
  ProcessResource(port: Port)
}

pub fn process_resource(port: Port) -> AgentResource {
  ProcessResource(port)
}

pub fn agent_resource_port(resource: AgentResource) -> Port {
  let ProcessResource(port) = resource
  port
}

/// Estado unificado del agente.
/// Combina provisioning y estado de runtime en un único ADT.
/// Flujo típico: Created → Provisioning → ReadyTransient|ReadyContinuous → Stopped → (Failed si error) → Delete
///
/// El tipo hace imposible representar estados inválidos:
/// - ReadyTransient: sin resource (agentes CLI)
/// - ReadyContinuous: con resource obligatorio (servidores)
/// No se necesita validación runtime porque el tipo lo garantiza.
pub type AgentState {
  /// Recién creado, parámetros resueltos, sin provisionar
  Created(params: ResolvedParams)

  /// Provisioning en curso
  Provisioning(params: ResolvedParams)

  /// Listo para interacciones - agente transient (CLI)
  /// No tiene resource porque se lanza un proceso por interacción
  ReadyTransient(params: ResolvedParams)

  /// Listo para interacciones - agente continuous (servidor)
  /// Resource es obligatorio (el servidor está corriendo)
  ReadyContinuous(params: ResolvedParams, resource: AgentResource)

  /// Instancia detenida: no acepta interacciones, pero sigue existiendo y conserva
  /// workspace/artefactos hasta que se ejecute Delete.
  Stopped(params: ResolvedParams)

  /// Falló (provision o runtime)
  Failed(reason: String)
}

// --- Constructores ---

/// Constructor para estado Created (siempre válido).
pub fn agent_created(params: ResolvedParams) -> AgentState {
  Created(params)
}

/// Constructor para estado Provisioning.
pub fn agent_provisioning(params: ResolvedParams) -> AgentState {
  Provisioning(params)
}

/// Constructor para agente transient listo.
pub fn agent_ready_transient(params: ResolvedParams) -> AgentState {
  ReadyTransient(params)
}

/// Constructor para agente continuous listo.
/// Requiere el resource (servidor corriendo).
pub fn agent_ready_continuous(
  params: ResolvedParams,
  resource: AgentResource,
) -> AgentState {
  ReadyContinuous(params, resource)
}

/// Constructor para estado Stopped.
pub fn agent_stopped(params: ResolvedParams) -> AgentState {
  Stopped(params)
}

/// Constructor para estado Failed (siempre válido).
pub fn agent_failed(reason: String) -> AgentState {
  Failed(reason)
}

// --- Introspección ---

pub fn is_created(state: AgentState) -> Bool {
  case state {
    Created(_) -> True
    _ -> False
  }
}

pub fn is_provisioning(state: AgentState) -> Bool {
  case state {
    Provisioning(_) -> True
    _ -> False
  }
}

pub fn is_ready(state: AgentState) -> Bool {
  case state {
    ReadyTransient(_) -> True
    ReadyContinuous(_, _) -> True
    _ -> False
  }
}

pub fn is_stopped(state: AgentState) -> Bool {
  case state {
    Stopped(_) -> True
    _ -> False
  }
}

pub fn is_ready_transient(state: AgentState) -> Bool {
  case state {
    ReadyTransient(_) -> True
    _ -> False
  }
}

pub fn is_ready_continuous(state: AgentState) -> Bool {
  case state {
    ReadyContinuous(_, _) -> True
    _ -> False
  }
}

pub fn is_failed(state: AgentState) -> Bool {
  case state {
    Failed(_) -> True
    _ -> False
  }
}

pub fn get_failure_reason(state: AgentState) -> Option(String) {
  case state {
    Failed(r) -> Some(r)
    _ -> None
  }
}

/// Obtiene el resource de un agente continuous.
/// Devuelve None para transient o estados no-ready.
pub fn get_resource(state: AgentState) -> Option(AgentResource) {
  case state {
    ReadyContinuous(_, r) -> Some(r)
    _ -> None
  }
}

pub fn get_params(state: AgentState) -> Option(ResolvedParams) {
  case state {
    Created(p) -> Some(p)
    Provisioning(p) -> Some(p)
    ReadyTransient(p) -> Some(p)
    ReadyContinuous(p, _) -> Some(p)
    Stopped(p) -> Some(p)
    Failed(_) -> None
  }
}

// ============================================================================
// SECCIÓN 8.1: CONFIGURACIÓN DEL SISTEMA (SaarConfig)
// ============================================================================
// Configuración global de SAAR cargada desde config.toml.
// Transparente porque no tiene invariantes complejos.

/// Configuración global del sistema SAAR.
/// Cargada desde config.toml al arranque.
pub type ProfileSource {
  ProfileSourceDir(path: String)
  ProfileSourceGit(url: String, ref: Option(String))
}

pub type SaarConfig {
  SaarConfig(
    // --- Server ---
    /// Host donde escuchar (ej: "0.0.0.0")
    server_host: String,
    /// Puerto HTTP
    server_port: Int,
    // --- Auth ---
    /// API key para autenticación (Bearer token)
    api_key: String,
    // --- Timeouts ---
    /// Timeout hard para interacciones (ms).
    /// No se resetea por output continuo del runner (protección contra loops infinitos).
    call_timeout_ms: Int,
    /// Timeout para consultas de status (ms)
    status_timeout_ms: Int,
    /// Timeout para operaciones del registry (ms)
    registry_timeout_ms: Int,
    /// Timeout para health checks de agentes continuous (ms)
    health_check_timeout_ms: Int,
    /// Tiempo de gracia para shutdown de agentes (ms)
    shutdown_timeout_ms: Int,
    // --- Profiles/Runners ---
    /// Fuentes de perfiles y runners (dir/git)
    profiles_sources: List(ProfileSource),
    /// Cache local para repos git
    profiles_git_cache_dir: String,
    /// Interprete para scripts .py
    runners_python_bin: String,
    /// Directorio base para workspaces de instancias
    workspaces_directory: String,
    // --- Limits ---
    /// Tamaño máximo del buffer de logs por agente (bytes)
    log_buffer_bytes: Int,
    /// Límite duro de bytes leídos desde STDOUT del runner (JSONL) por interacción (bytes).
    /// Aplica tanto en streaming como en non-streaming: protección contra runners buggy/maliciosos.
    max_stdout_bytes: Int,
    /// Límite duro por línea JSONL (runner/streaming).
    max_runner_event_bytes: Int,
    /// Límite duro del body que SAAR acepta en requests entrantes (bytes).
    /// Se aplica al leer/parsing de JSON en gateway (Mist: `read_body`).
    max_request_body_bytes: Int,
    /// Límite duro del body que SAAR acepta desde agentes HTTP en modo non-streaming (bytes).
    /// Evita OOM si un agente devuelve respuestas enormes.
    max_http_response_bytes: Int,
    /// Límite duro de bytes que SAAR descargará al construir multipart desde `FileRef` (SAAR → agente).
    /// Protege de URLs que devuelven ficheros gigantes.
    max_file_fetch_bytes: Int,
    /// Puerto mínimo para asignar a agentes continuous
    port_range_min: Int,
    /// Puerto máximo para asignar a agentes continuous
    port_range_max: Int,
    /// Intervalo de keep-alive SSE (ms). 0 desactiva.
    sse_keep_alive_interval_ms: Int,
    /// Configuración del stream de logs (SSE de instancia)
    log_stream: LogStreamConfig,
    /// Configuración del stream de interacción (SSE de respuesta)
    interaction_stream: InteractionStreamConfig,
    // --- Network ---
    /// Host inyectado para managed_port
    managed_port_host: String,
  )
}

/// Valores por defecto para SaarConfig.
/// Usados cuando config.toml no especifica un valor.
pub fn default_saar_config() -> SaarConfig {
  SaarConfig(
    server_host: "0.0.0.0",
    server_port: 8080,
    api_key: "",
    // Debe sobrescribirse
    call_timeout_ms: 30_000,
    status_timeout_ms: 5000,
    registry_timeout_ms: 5000,
    health_check_timeout_ms: 10_000,
    shutdown_timeout_ms: 10_000,
    profiles_sources: [ProfileSourceDir(path: ".")],
    profiles_git_cache_dir: "./.saar/cache/git",
    runners_python_bin: "python3",
    workspaces_directory: "./workspaces",
    log_buffer_bytes: 1_048_576,
    // 1MB
    max_stdout_bytes: 10_485_760,
    // 10MB - límite de stdout acumulado
    max_runner_event_bytes: 262_144,
    max_request_body_bytes: 1_048_576,
    // 1MB - límite de body entrante (JSON)
    max_http_response_bytes: 10_485_760,
    // 10MB - límite de body HTTP non-streaming
    max_file_fetch_bytes: 52_428_800,
    // 50MB - límite de fetch para multipart via URL
    port_range_min: 9000,
    port_range_max: 9999,
    sse_keep_alive_interval_ms: 15_000,
    log_stream: LogStreamConfig(batch_byte_size: 4096, flush_interval_ms: 50),
    interaction_stream: InteractionStreamConfig(
      batch_byte_size: 4096,
      flush_interval_ms: 25,
      push_timeout_ms: 250,
    ),
    managed_port_host: "127.0.0.1",
  )
}

/// Resuelve el timeout efectivo para una interacción.
/// Prioridad: capability limits > config default
pub fn resolve_call_timeout(
  config: SaarConfig,
  limits: Option(CapabilityLimits),
) -> Int {
  case limits {
    None -> config.call_timeout_ms
    Some(l) -> option.unwrap(l.call_timeout_ms, config.call_timeout_ms)
  }
}

/// Resuelve el timeout efectivo para una interacción, a partir de la Interface y el nombre
/// de la capability (lookup + delegación a `resolve_call_timeout/2`).
pub fn resolve_call_timeout_for(
  config: SaarConfig,
  interface: Interface,
  capability_name: String,
) -> Int {
  let limits = case interface {
    HttpInterface(_, _, _, capabilities) -> {
      case dict.get(capabilities, capability_name) {
        Ok(cap) -> cap.limits
        Error(_) -> None
      }
    }
    RunnerInterface(capabilities) -> {
      case dict.get(capabilities, capability_name) {
        Ok(cap) -> cap.limits
        Error(_) -> None
      }
    }
  }

  resolve_call_timeout(config, limits)
}

// ============================================================================
// FILE: saar/core/messages.gleam (mensajería OTP; Subject/Pid/Monitor/Selector)
// ============================================================================
import gleam/erlang/process.{
  type Down, type Monitor, type Pid, type Selector, type Subject,
}

// ============================================================================
// SECCIÓN 9: ESTADO DEL ACTOR (ADT EXPLÍCITO)
// ============================================================================
// El actor usa un ADT para su modo operativo, no flags Option.
// Esto hace estructuralmente imposible estados inválidos.
//
// Ubicación: `saar/core/agent.gleam` (estado del actor) + `saar/core/messages.gleam` (handles/canales).

/// Modo operativo del actor. ADT explícito en lugar de Option(InFlight).
pub type ActorMode {
  /// Listo para recibir interacciones
  Idle
  /// Procesando una interacción
  Busy(in_flight: InFlight)
}

/// Información de una interacción en curso.
pub type InFlight {
  InFlight(
    request: AgentRequest,
    reply_to: ReplyChannel,
    handle: InteractionHandle,
  )
}

/// Request interna del actor (ya normalizada).
pub type AgentRequest {
  AgentRequest(
    profile_id: ProfileId,
    instance_id: InstanceId,
    capability: String,
    trace_id: TraceId,
    inputs: InputPayload,
    context: RequestContext,
  )
}

/// Alias semántico para el canal de respuesta.
/// No es opaco porque no tiene invariantes - es simplemente un Subject tipado.
/// El tipo largo se documenta aquí para claridad; usar ReplyChannel en firmas.
// Ubicación: saar/core/messages.gleam

pub type ReplyChannel =
  Subject(Result(InteractionResult, InteractionError))

/// Handle para una interacción en curso.
/// Incluye el PID del worker y un monitor para detectar si muere.
/// Opaco para encapsular detalles de implementación.
// Ubicación: saar/core/messages.gleam

pub opaque type InteractionHandle {
  InteractionHandle(
    /// PID del proceso worker que ejecuta la interacción
    pid: Pid,
    /// Monitor del worker para detectar crashes
    monitor: Monitor,
  )
}

/// Crea un handle de interacción con su monitor.
// Ubicación: saar/core/messages.gleam

pub fn interaction_handle(pid: Pid, monitor: Monitor) -> InteractionHandle {
  InteractionHandle(pid, monitor)
}

/// Obtiene el PID del worker.
// Ubicación: saar/core/messages.gleam

pub fn interaction_handle_pid(handle: InteractionHandle) -> Pid {
  handle.pid
}

/// Obtiene el monitor del worker.
// Ubicación: saar/core/messages.gleam

pub fn interaction_handle_monitor(handle: InteractionHandle) -> Monitor {
  handle.monitor
}

/// Razón de parada del agente.
pub type StopReason {
  UserRequested
  Deleted
  SupervisorCleanup
  NodeShuttingDown
  IdleTimeout
}

// Introspección externa/wire:
// - `AgentStatusView` y `AgentInfoView` viven en `saar/types.gleam` y son serializables (sin OTP/secrets).
// Introspección interna:
// - `AgentRuntimeState` (record de estado del actor) + `ActorMode` viven en `saar/core/agent.gleam` y NO se exponen por HTTP.

// ============================================================================
// SECCIÓN 10: LOGGING
// ============================================================================

/// Fuente de un evento de log.
pub type LogSource {
  /// Stderr del proceso runner
  StdErr
  /// Log de aplicación (archivos declarados)
  AppLog
  /// Eventos del sistema SAAR (tipados via SystemLogKind)
  SystemLog
}

/// Evento de log con metadata estructurada.
pub type LogEvent {
  LogEvent(
    source: LogSource,
    line: String,
    /// Timestamp en milliseconds since epoch
    ts_ms: Int,
    /// TraceId asociado (None para logs de servidor continuous sin request activo)
    trace_id: Option(TraceId),
    /// InstanceId del agente que generó el log
    instance_id: InstanceId,
  )
}

/// Constructor conveniente para LogEvent que captura timestamp actual.
pub fn log_event(
  source: LogSource,
  line: String,
  trace_id: Option(TraceId),
  instance_id: InstanceId,
) -> LogEvent {
  LogEvent(
    source: source,
    line: line,
    ts_ms: now_ms(),
    trace_id: trace_id,
    instance_id: instance_id,
  )
}

// --- SYSTEM LOG TIPADO ---

/// Tipos de eventos de sistema para métricas y observabilidad.
/// Enum cerrado: permite contar eventos por tipo en pipelines de logs.
pub type SystemLogKind {
  /// Agente arrancó exitosamente
  AgentStarted
  /// Agente detenido (normal o por error)
  AgentStopped
  /// Interacción iniciada
  InteractionStarted
  /// Interacción completada exitosamente
  InteractionFinished
  /// Interacción falló
  InteractionFailed
  /// Health check falló (solo continuous)
  HealthCheckFailed
  /// Provisioning iniciado
  ProvisioningStarted
  /// Provisioning completado
  ProvisioningFinished
  /// Provisioning falló
  ProvisioningFailed
  /// Servidor continuous murió inesperadamente
  ServerDied
}

/// Convierte SystemLogKind a string para serialización.
pub fn system_log_kind_to_string(kind: SystemLogKind) -> String {
  case kind {
    AgentStarted -> "agent_started"
    AgentStopped -> "agent_stopped"
    InteractionStarted -> "interaction_started"
    InteractionFinished -> "interaction_finished"
    InteractionFailed -> "interaction_failed"
    HealthCheckFailed -> "health_check_failed"
    ProvisioningStarted -> "provisioning_started"
    ProvisioningFinished -> "provisioning_finished"
    ProvisioningFailed -> "provisioning_failed"
    ServerDied -> "server_died"
  }
}

/// Constructor tipado para logs de sistema.
/// Genera línea estructurada parseable por pipelines de métricas.
/// Formato: "kind=<kind> <key1>=<value1> <key2>=<value2> ..."
///
/// Ejemplo de uso:
/// ```gleam
/// system_log(
///   AgentStarted,
///   dict.from_list([#("profile", "aider"), #("lifecycle", "transient")]),
///   None,
///   instance_id,
/// )
/// // Genera: "kind=agent_started profile=aider lifecycle=transient"
/// ```
pub fn system_log(
  kind: SystemLogKind,
  labels: Dict(String, String),
  trace_id: Option(TraceId),
  instance_id: InstanceId,
) -> LogEvent {
  let kind_str = "kind=" <> system_log_kind_to_string(kind)

  let labels_str =
    labels
    |> dict.to_list
    |> list.map(fn(pair) { pair.0 <> "=" <> pair.1 })
    |> string.join(" ")

  let line = case labels_str {
    "" -> kind_str
    _ -> kind_str <> " " <> labels_str
  }

  log_event(SystemLog, line, trace_id, instance_id)
}

// ============================================================================
// SECCIÓN 11: STREAMING (GENÉRICO)
// ============================================================================
// Tipos genéricos de streaming para el core de SAAR.
// El core emite eventos agnósticos del protocolo de presentación.
// Los adapters (agui.gleam, a2a.gleam) traducen a formatos específicos.
//
// Patrón consistente con A2A: core genérico + adapters de protocolo.

/// Evento de streaming genérico.
/// Representa lo que el core sabe: chunks de contenido y eventos de lifecycle.
/// Los adapters (AG-UI, A2A) traducen esto a sus formatos específicos.
pub type StreamEvent {
  /// Chunk de contenido textual.
  /// El adapter decide cómo presentarlo (TEXT_MESSAGE_CONTENT en AG-UI,
  /// `message` en A2A, etc.)
  ContentChunk(
    /// ID de la ejecución (trace_id)
    trace_id: TraceId,
    /// Contenido del chunk
    content: String,
    /// Timestamp en milliseconds
    timestamp: Int,
  )

  /// Inicio de ejecución.
  StreamStarted(trace_id: TraceId, timestamp: Int)

  /// Fin exitoso de ejecución.
  StreamFinished(trace_id: TraceId, timestamp: Int)

  /// Error durante ejecución.
  StreamError(trace_id: TraceId, error: InteractionError, timestamp: Int)
}

// --- Constructores de eventos ---

/// Constructor para inicio de stream.
pub fn stream_started(trace_id: TraceId) -> StreamEvent {
  StreamStarted(trace_id, now_ms())
}

/// Constructor para chunk de contenido.
pub fn content_chunk(trace_id: TraceId, content: String) -> StreamEvent {
  ContentChunk(trace_id, content, now_ms())
}

/// Constructor para fin de stream.
pub fn stream_finished(trace_id: TraceId) -> StreamEvent {
  StreamFinished(trace_id, now_ms())
}

/// Constructor para error de stream.
pub fn stream_error(trace_id: TraceId, error: InteractionError) -> StreamEvent {
  StreamError(trace_id, error, now_ms())
}

// --- Contexto de streaming ---

/// Fase del stream dentro de una interacción.
/// Una interacción puede contener múltiples mensajes (AG-UI).
/// 
/// Flujo típico:
///   BeforeFirstChunk → InMessage("msg-1") → BeforeFirstChunk → InMessage("msg-2") → ...
pub type StreamPhase {
  /// Antes del primer chunk de un mensaje (o entre mensajes)
  BeforeFirstChunk
  /// Dentro de un mensaje con el ID especificado
  InMessage(message_id: String)
}

/// Contexto para tracking de streaming.
/// Mantiene estado necesario para que los adapters generen IDs consistentes.
/// 
/// NOTA: instance_id es obligatorio porque el streaming siempre ocurre
/// en el contexto de una interacción con un agente específico.
pub type StreamContext {
  StreamContext(
    /// ID de la ejecución
    trace_id: TraceId,
    /// ID de instancia (siempre presente en interacciones)
    instance_id: InstanceId,
    /// Fase actual del stream (ADT en lugar de bool + Option)
    phase: StreamPhase,
  )
}

/// Crea contexto de streaming inicial.
pub fn new_stream_context(
  trace_id: TraceId,
  instance_id: InstanceId,
) -> StreamContext {
  StreamContext(
    trace_id: trace_id,
    instance_id: instance_id,
    phase: BeforeFirstChunk,
  )
}

/// Transición: entramos en un mensaje (o continuamos en él).
/// Si ya estamos en un mensaje con otro ID, cambia al nuevo.
pub fn enter_message(ctx: StreamContext, message_id: String) -> StreamContext {
  StreamContext(..ctx, phase: InMessage(message_id))
}

/// Transición: terminamos el mensaje actual, listos para el siguiente.
pub fn end_message(ctx: StreamContext) -> StreamContext {
  StreamContext(..ctx, phase: BeforeFirstChunk)
}

/// Verifica si estamos antes del primer chunk de un mensaje.
pub fn is_before_first_chunk(ctx: StreamContext) -> Bool {
  case ctx.phase {
    BeforeFirstChunk -> True
    InMessage(_) -> False
  }
}

/// Obtiene el message_id actual si estamos dentro de un mensaje.
pub fn current_message_id(ctx: StreamContext) -> Option(String) {
  case ctx.phase {
    BeforeFirstChunk -> None
    InMessage(id) -> Some(id)
  }
}

// --- Helpers ---

/// Genera un message_id único.
/// Usa la librería youid para generar UUIDs sin FFI.
/// v7 es ordenable cronológicamente, ideal para mensajes.
pub fn generate_message_id() -> String {
  "msg-" <> uuid.v7_string()
}

// ============================================================================
// SECCIÓN 12: UTILIDADES DE TIEMPO
// ============================================================================
// 
// NOTA: now_ms() vive en saar/ffi.gleam (SSOT para toda la FFI).
// Aquí solo re-exportamos para conveniencia de los módulos de dominio.
// Ver `bridge.md` §FFI para la implementación.

/// Obtiene timestamp actual en milliseconds since epoch.
/// Delegado a saar/ffi.now_ms() para mantener SSOT.
pub fn now_ms() -> Int {
  ffi.now_ms()
}
