# Guía de integración para clientes de SAAR

Este documento está dirigido a desarrolladores que construyen clientes que consumen SAAR (por ejemplo, un cliente tipo SAM).

Se centra en:

- Descubrir y seleccionar capacidades.
- Consumir respuestas según el modo de entrega (inmediata, por SSE, o diferida).
- Tratar correctamente los estados de “ocupado” y la distinción entre “fallo” y “cancelación”.

## 1. Descubrir capacidades

Una instancia de SAAR expone sus capacidades a través del API `/agents`.

- `GET /agents/:instance_id` devuelve un objeto que incluye `capabilities`.
- Cada entrada de `capabilities` describe el esquema de entrada (`input_schema`), el modo de entrega (`response_mode`), si soporta SSE (`streaming`) y límites opcionales (`limits`).

El diccionario `capabilities` es la lista autoritativa de operaciones que un cliente puede invocar.

Para decidir cómo consumir la respuesta, el cliente debe leer:

- `capabilities.<cap>.response_mode` (`sync`, `stream`, `deferred`).
- `capabilities.<cap>.streaming` (si soporta SSE).

### 1.1 Semantica de ficheros por capability

Si una capability acepta ficheros, la vista nativa incluye un bloque `files`:

- `files.accepts`: indica si acepta ficheros.
- `files.max_files`: cardinalidad maxima permitida.
- `files.ingest_effect`: `immediate` o `eventual`.

Si `ingest_effect = "eventual"`, el cliente no debe asumir que un upload afecta
de forma inmediata a consultas posteriores.

## 2. Invocar una capacidad (API nativa)

Los clientes invocan capacidades usando:

- `POST /agents/:instance_id/interact`

El cuerpo incluye:

- `capability`: el nombre de la capacidad (clave dentro de `capabilities`).
- `inputs`: un objeto JSON que respeta `input_schema`.
- `context.trace_id`: un identificador aportado por el cliente para correlación y trazabilidad.

### 2.1 Metadatos de ingesta en respuestas

Cuando la capability implica ingesta de ficheros, SAAR incluye metadatos
estables en `data.metadata`:

- `ingest_effect`: `immediate` o `eventual`.
- `max_files`: cardinalidad maxima.
- `track_id`: identificador opcional si el agente lo devuelve.

Estos metadatos son informativos; no implican garantia de indexacion inmediata.

### 2.2 Estado ocupado (422)

Si la instancia está ocupada (sin cola), SAAR responde `422` con un Problem Details `agent_error`.
El cliente debe reintentar más tarde o usar otra instancia.

### 2.1 Qué significa `capability`

`capability` no es una promesa sobre lo que el producto “agente” implementa internamente.

Es un contrato de SAAR: el perfil decide cómo se implementa cada capacidad.

- En perfiles basados en runner (`protocol: runner`), una capacidad es una operación “virtual” implementada por la forma en la que el perfil invoca al runner (argumentos, entorno, helpers).
- En perfiles basados en HTTP (`protocol: http`), una capacidad suele mapear a un endpoint HTTP upstream distinto (`path` + `method`) con su plantilla de request y su mapeo de respuesta.

## 3. Modos de entrega de respuesta

Cada capacidad determina cómo SAAR entregará el resultado al cliente. El campo `response_mode` controla este comportamiento.

### 3.1 Respuesta inmediata (JSON)

SAAR devuelve la respuesta final en la misma llamada HTTP. Es el modo por defecto cuando `response_mode` no está presente.

Comportamiento esperado del cliente:

- Esperar `200`.
- Procesar el cuerpo JSON.
- Si hay `artifacts`, descargarlos/consumirlos en el momento.

### 3.2 Respuesta por SSE (emisión progresiva)

SAAR devuelve `text/event-stream` (SSE) y emite eventos hasta un evento terminal. Este modo requiere `response_mode = "stream"` y `streaming = true`.

Comportamiento esperado del cliente:

- Mantener la conexión abierta y procesar eventos según llegan.
- Si el cliente corta la conexión, deja de recibir eventos; la ejecución puede continuar en SAAR.
- SAAR no soporta reanudar ni repetir eventos de una interacción tras desconexión.

### 3.3 Respuesta diferida (tarea + sondeo / suscripción)

SAAR devuelve inmediatamente un identificador de tarea, y el cliente recupera el resultado más tarde. Este modo requiere `response_mode = "deferred"` y `streaming = false`.

#### 3.3.1 Crear tarea (API nativa)

La misma ruta `POST /agents/:instance_id/interact` puede responder de forma diferida si la capacidad seleccionada está marcada para ello.

**Request:**

```http
POST /agents/:instance_id/interact
Authorization: Bearer <api_key>
Content-Type: application/json

{
  "capability": "train",
  "inputs": {
    "messages": [{"role":"user","content":"Entrena con este esquema"}]
  },
  "context": {"trace_id": "trace-train-001"}
}
```

**Response (202):**

```json
{
  "task_id": "trace-train-001",
  "state": "running",
  "instance_id": "<instance_id>",
  "capability": "train",
  "links": {
    "get": "/tasks/trace-train-001",
    "subscribe": "/tasks/trace-train-001/subscribe"
  }
}
```

##### 3.3.1.1 Esquema mínimo (estable) de la respuesta 202

SAAR garantiza que una respuesta diferida (`202`) contiene como mínimo:

- `task_id: string`
- `state: "running"`
- `instance_id: string`
- `capability: string`
- `links.get: string` (ruta absoluta o relativa para consultar la tarea)
- `links.subscribe: string` (ruta absoluta o relativa para suscribirse)

Notas:

- `task_id` debe ser estable y se recomienda que el cliente lo derive de `context.trace_id`.
- El cliente no recibe el resultado aquí; debe consultarlo por sondeo o suscripción.

- `task_id` es estable y se recomienda que el cliente lo derive de `context.trace_id`.
- El cliente no recibe el resultado aquí; debe consultarlo por sondeo o suscripción.

#### 3.3.2 Consultar una tarea (sondeo)

**Request:**

```http
GET /tasks/:task_id
Authorization: Bearer <api_key>
```

**Response (200):**

```json
{
  "task_id": "trace-train-001",
  "instance_id": "<instance_id>",
  "capability": "train",
  "state": "running"
}
```

##### 3.3.2.1 Esquema mínimo (estable) de `GET /tasks/:task_id`

SAAR garantiza que la consulta de una tarea (`200`) devuelve como mínimo:

- `task_id: string`
- `instance_id: string`
- `capability: string`
- `state: "running" | "completed" | "failed" | "cancelled"`

Reglas de consistencia (para que un cliente pueda validar sin ambigüedad):

- Si `state = "running"`:
  - no deben aparecer `result` ni `error`.
- Si `state = "completed"`:
  - debe aparecer `result`.
  - no debe aparecer `error`.
- Si `state = "failed"`:
  - debe aparecer `error`.
  - no debe aparecer `result`.
- Si `state = "cancelled"`:
  - debe aparecer `error` con `message = "cancelled"`.
  - no debe aparecer `result`.

Campos opcionales:

- `artifacts: PublicArtifact[]`
  - puede aparecer en estados terminales.
  - el cliente debe asumir que `url` puede ser null.

Errores:

- `404` si el `task_id` no existe.

### 3.4 Cancelled vs failed

- `failed` implica que la ejecución terminó con un error propio del agente o del bridge.
- `cancelled` implica que SAAR detuvo la interacción (por `DELETE /tasks/:task_id`,
  `POST /sys/agents/:instance_id/stop` o `DELETE /sys/agents/:instance_id`).

Cuando la tarea es terminal, aparece `result` o `error`:

```json
{
  "task_id": "trace-train-001",
  "instance_id": "<instance_id>",
  "capability": "train",
  "state": "completed",
  "result": {
    "content": "Entrenamiento completado."
  },
  "artifacts": [
    {"id":"01J...","name":"report.pdf","url":null,"mime":"application/pdf"}
  ]
}
```

```json
{
  "task_id": "trace-train-001",
  "instance_id": "<instance_id>",
  "capability": "train",
  "state": "failed",
  "error": {"message": "..."}
}
```

```json
{
  "task_id": "trace-train-001",
  "instance_id": "<instance_id>",
  "capability": "train",
  "state": "cancelled",
  "error": {"message": "cancelled_by_sad"}
}
```

#### 3.3.3 Suscribirse a una tarea (SSE)

**Request:**

```http
GET /tasks/:task_id/subscribe
Authorization: Bearer <api_key>
Accept: text/event-stream
```

**Respuesta:** un stream SSE que cumple estas reglas:

- El **primer evento** es siempre un snapshot del estado actual.
- Después se emiten eventos cuando el estado cambia.
- El stream se cierra al llegar a estado terminal.

##### 3.3.3.1 Esquema mínimo (estable) que emite SAAR

SAAR emitirá eventos con `event: task`.

**Evento SSE (`event: task`):**

`data: TaskView`

**`TaskView`:**

- `task_id: string` (igual a `context.trace_id` cuando se proporciona)
- `instance_id: string`
- `capability: string`
- `state: string`
  - no terminal: `running`
  - terminales: `completed` | `failed` | `cancelled`
- opcional en terminal:
  - `result: {"content": string}` (si `completed`)
  - `error: {"message": string}` (si `failed` o `cancelled`)
  - `artifacts: PublicArtifact[]` (si aplica)

**`PublicArtifact`:**

- `id: string`
- `name: string`
- `url: string | null`
- `mime: string`

Notas operativas:

- El cliente debe asumir que `url` puede ser null.
- SAAR no garantiza artefactos tras reinicio.
- `cancelled` significa cancelación iniciada por SAAR; no se debe tratar como `failed`.

Ejemplo:

```
event: task
data: {"task_id":"trace-train-001","state":"running"}

event: task
data: {"task_id":"trace-train-001","state":"completed","result":{"content":"OK"}}
```

#### 3.3.4 Cancelar o borrar una tarea

SAAR expone `DELETE /tasks/:task_id` con una semántica doble:

- Si la tarea está `running`, `DELETE` la cancela y la deja en estado terminal `cancelled`.
- Si la tarea ya es terminal, `DELETE` la borra (deja de estar disponible y un `GET` posterior devuelve `404`).

Nota: la cancelación es best-effort con respecto al proceso subyacente, pero el estado visible al cliente debe quedar como `cancelled`.

#### 3.3.5 Idempotencia por `trace_id`

Para evitar tareas duplicadas:

- Si el cliente envía `context.trace_id` y reintenta la misma petición, SAAR debe devolver la **misma** tarea (`task_id = trace_id`) en lugar de crear otra.

Esto permite que un cliente como SAM sea robusto frente a reintentos de red.

Retención y reinicios:

- SAAR guarda resultados de tareas en memoria hasta que el cliente los consulta, los borra, o hasta que expire la retención.
- SAAR no garantiza tareas ni artefactos tras reinicio. Un cliente debe asumir que, tras un reinicio, tendrá que reintentar.

## 4. Agente ocupado (sin cola)

SAAR no mantiene cola de interacciones por instancia.

Si se envía una interacción mientras el agente ya está ejecutando otra:

- `POST /agents/:instance_id/interact` devuelve un error `422` indicando que el agente está ocupado.

Comportamiento esperado del cliente:

- No reintentar en bucle cerrado.
- Consultar el estado de la instancia (por ejemplo el campo público `mode`) y reintentar con backoff.

## 5. Cancelación vs fallo

Un cliente debe distinguir explícitamente:

- **Fallo (`failed`)**: el agente devolvió error o SAAR no pudo completar por un problema de infraestructura.
- **Cancelación (`cancelled`)**: SAAR abortó deliberadamente la ejecución (por ejemplo, stop/delete de instancia, apagado, o enforcement interno).

En la API de tareas, una cancelación debe aparecer como estado terminal `cancelled`, no como `failed`.

Esto es clave para el comportamiento del cliente:

- Un fallo puede ser reintentable dependiendo del caso.
- Una cancelación suele ser una decisión explícita y no debería reintentarse automáticamente.

## 6. Fachada A2A

El protocolo A2A está diseñado para trabajos de larga duración y procesamiento asíncrono.

Si una petición devuelve una tarea A2A en estado no terminal (por ejemplo `working`), A2A espera que el servidor soporte operaciones de tarea:

- obtener el estado de una tarea (sondeo),
- cancelar una tarea,
- suscribirse a actualizaciones de una tarea existente.

### 6.1 Enviar mensaje

Ruta existente:

- `POST /instances/:instance_id/a2a/message:send`

Contrato de alto nivel:

- Si SAAR puede resolver la petición “en el acto”, devuelve una tarea terminal (`completed`) con el mensaje final.
- Si la capacidad es de ejecución larga (respuesta diferida), devuelve una tarea no terminal (`working`) y el cliente debe consultar o suscribirse usando las rutas de tareas.

Ejemplo (respuesta no terminal):

```json
{
  "result": {
    "id": "trace-train-001",
    "contextId": "conv-77",
    "status": {"state": "working"}
  }
}
```

Nota: cuando `status.state` es no terminal (`working`, etc.), un cliente A2A debe poder continuar el ciclo de vida con “obtener tarea”, “cancelar tarea” y/o “suscribirse a tarea”.

### 6.2 Obtener tarea (sondeo)

Ruta propuesta:

- `GET /instances/:instance_id/a2a/tasks/:task_id`

Devuelve el objeto `Task` (o equivalente) con el estado actual, y en terminal incluye el mensaje final y/o artefactos.

### 6.3 Cancelar tarea

Ruta propuesta:

- `POST /instances/:instance_id/a2a/tasks/:task_id:cancel`

La cancelación debe dejar la tarea en estado terminal `cancelled` (no `failed`).

### 6.4 Suscribirse a una tarea (SSE)

Ruta propuesta:

- `POST /instances/:instance_id/a2a/tasks/:task_id:subscribe`

Reglas mínimas para que sea funcional:

- El primer evento debe contener un snapshot de la tarea.
- Después se emiten actualizaciones de estado.
- El stream se cierra en estado terminal.

Formato SSE (A2A): cada `data: ...` contiene un JSON que representa un `StreamResponse`.

Regla importante: un `StreamResponse` debe contener exactamente uno de estos campos:

- `task`
- `message`
- `statusUpdate`
- `artifactUpdate`

#### 6.4.1 Esquema mínimo (estable) que emite SAAR

La fachada A2A de SAAR emitirá un subconjunto estable del modelo A2A (lo mínimo para ser interoperable y fácil de consumir).

**`StreamResponse` (SSE `data:`):**

- `{"task": Task}`
- `{"message": Message}`
- `{"statusUpdate": TaskStatusUpdateEvent}`
- `{"artifactUpdate": TaskArtifactUpdateEvent}` (solo si aplica)

**`Task` (campo `task`):**

- `id: string` (igual a `trace_id`)
- `contextId: string` (si el cliente lo envió; si no, SAAR genera uno)
- `status.state: string`
  - no terminal: `working`
  - terminales: `completed` | `failed` | `cancelled`
- opcional en terminal:
  - `message: Message` (respuesta final)
  - `artifacts: Artifact[]` (si hubo artefactos)

**`TaskStatusUpdateEvent` (campo `statusUpdate`):**

- `taskId: string` (igual a `trace_id`)
- `contextId: string`
- `status.state: string` (mismos valores que en `Task.status.state`)

**`Message` (campo `message` o `Task.message`):**

- `role: "assistant" | "user"`
- `parts: Part[]`

Para clientes tipo SAM, el caso más común será `parts` conteniendo `TextPart`:

- `{"text": "..."}`

**`Artifact` (en `Task.artifacts`):**

- `id: string`
- `name: string`
- `uri: string | null` (puede ser null)
- `mediaType: string`

Notas operativas:

- SAAR no garantiza disponibilidad de artefactos tras reinicio; el cliente debe descargarlos cuando estén disponibles.
- SAAR preserva la distinción entre `failed` y `cancelled` (cancelled implica cancelación iniciada por SAAR).

Ejemplo:

```
data: {"task": {"id": "trace-train-001", "contextId": "conv-77", "status": {"state": "working"}}}

data: {"statusUpdate": {"taskId": "trace-train-001", "contextId": "conv-77", "status": {"state": "working"}}}

data: {"message": {"role": "assistant", "parts": [{"text": "Generando informe..."}]}}

data: {"statusUpdate": {"taskId": "trace-train-001", "contextId": "conv-77", "status": {"state": "completed"}}}
```

### 6.5 Identificadores

SAAR usa `trace_id` como identificador estable de tarea, tanto en superficie nativa como en A2A:

- `task_id` (nativo) = `trace_id`
- `taskId` (A2A) = `trace_id`
