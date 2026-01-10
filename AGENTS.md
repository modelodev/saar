# AGENTS.md (instrucciones generales para el proyecto)

Este repositorio es un proyecto Gleam/BEAM con `target = erlang"`.

## Convenciones de código

- Los métodos no deben superar las 100 líneas salvo justificación clara.
- No debe haber 3 cases anidados, y 2 cases anidados se permiten con justificación.

## Convenciones de documentación

- En gleam, puede usarse tanto:
  - `//` para comentarios normales.
  - `///` para comentar tipos y funciones, se debe colocar justo antes de la definición del tipo o función que se quiere documentar.
  - `////` para documentar un módulo, se debe usar justo al principio del módulo.
- En el proyecto, debe documentarse:
    - Cada módulo, indicando:
        - La misión del módulo.
        - Que responsabilidades asume y qué responsabilidades NO debe asumir.
        - Como se relaciona con otros módulos, tanto a nivel de tipos como de métodos.
    - Cada método público, indicando su función y ejemplos de uso.
    - Cada tipo público, indicando cual es su propósito.
- La documentación sobre código siempre debe ir en inglés, y ser concisa.
- Siempre que se edite código, se debe revisar si la edición ha cambiado el propósito de la función o tipo, o del propio módulo, y actualizar la documentación asociada.

## Comunicación

- Cuando te pregunten, responde siempre en el idioma de la pregunta. Si éste no es inglés, responde sin anglicismos.
- Si te preguntan dudas sobre código, responde dando contexto para que el interlocutor entienda el objetivo del código sobre el que pregunta, para qué se usa y para qué no y tenga claro como se relaciona con otros tipos o funciones (o módulos).

