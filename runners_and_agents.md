# Runners y agentes

Este documento explica cómo SAD conecta “agentes reales” (CLI y servidores HTTP) con instancias de SAD usando perfiles, runners y capacidades.

## Conceptos

### Instancia

Una instancia es un agente en ejecución gestionado por SAD. Las instancias se crean a partir de un perfil (un documento JSON).

### Perfil

Un perfil describe:

- Cómo arrancar/provisionar un agente (definición de runner).
- Qué interfaz expone (`runner` o `http`).
- Qué capacidades están disponibles para clientes.

### Capacidad

Una capacidad es una operación visible para el cliente expuesta por una instancia de SAD.

- Las capacidades se declaran en el perfil bajo `interface.capabilities`.
- Los clientes (API nativa y A2A) referencian capacidades por nombre.
- SAD usa ese nombre como clave para decidir cómo invocar al agente.

Importante: las capacidades forman parte del contrato de SAD. No tienen por qué existir como concepto de “primer nivel” en el producto agente subyacente.

## Cómo se materializan las capacidades

### Interfaz runner (`protocol: runner`)

En perfiles basados en runner, las capacidades son operaciones “virtuales”. Se implementan por la forma en la que el perfil invoca al runner, no por el agente subyacente.

Implicaciones:

- Un CLI sin sistema de capacidades (por ejemplo, Aider) puede exponer capacidades en SAD.
- Si el agente solo soporta “una cosa”, el perfil suele exponer una única capacidad (comúnmente `chat`).
- Si se quieren varias operaciones, se definen varias capacidades y cada una se mapea a distintos argumentos y/o variables de entorno (o incluso a un runner distinto).

Ejemplo: `docs/arquitectura/examples/profiles/aider/aider.json` expone `chat` y lo mapea a `aider --message {{helpers.last_user_content}}`.

### Interfaz HTTP (`protocol: http`)

En perfiles basados en HTTP, las capacidades suelen mapear a endpoints upstream distintos.

- El perfil especifica `path` y `method`.
- El perfil construye el cuerpo de la request usando plantillas (incluyendo JSON Pointers).
- El perfil declara cómo extraer contenido y artefactos mediante mapeos declarativos.

Ejemplo: `docs/arquitectura/examples/profiles/lightrag/lightrag.json` expone `chat` y `files`, que mapean a `/query` y `/documents/upload`.

## Modos de entrega de respuesta

Una capacidad también define cómo SAD entrega el resultado a los clientes.

### Respuesta inmediata

SAD devuelve la respuesta final en la misma llamada HTTP.

Este es el modo por defecto para operaciones cortas.

### Respuesta por SSE (emisión progresiva)

SAD devuelve una respuesta SSE (`text/event-stream`) y emite eventos incrementales hasta el evento terminal.

Este modo requiere `streaming: true` y que el agente/runner pueda producir salida incremental (`t="chunk"` en JSONL de runner o eventos SSE upstream).

### Respuesta diferida (tarea + sondeo / suscripción)

SAD devuelve inmediatamente un identificador de tarea y el cliente recupera el resultado más tarde (por sondeo o suscripción de tarea).

Notas operativas:

- SAD no mantiene cola por instancia. Si el agente está ocupado, nuevas interacciones se rechazan.
- Los resultados de tareas se guardan en memoria hasta que se consulten, se borren, o expire la retención.
- SAD no garantiza que tareas o artefactos sobrevivan a un reinicio; un cliente debe descargar artefactos cuando estén disponibles.

## Visibilidad de “ocupado”

SAD expone explícitamente el estado de “ocupado”:

- Interacciones enviadas mientras ya hay una ejecución en curso se rechazan.
- Los clientes pueden observar el estado mediante endpoints de status (por ejemplo el campo público `mode`) y reintentar más tarde con backoff.

## Semántica de cancelación

SAD distingue entre fallo del agente y cancelación iniciada por SAD.

- `failed`: el agente (o un upstream) devolvió un error.
- `cancelled`: SAD abortó la ejecución (por ejemplo stop/delete, apagado del nodo, o enforcement interno).

Las APIs deben preservar esta distinción para que los clientes puedan decidir correctamente si reintentar o no.
