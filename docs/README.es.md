🌐 [English](../README.md) · [Deutsch](README.de.md) · **Español** · [Français](README.fr.md) · [Italiano](README.it.md) · [Português](README.pt.md) · [Nederlands](README.nl.md) · [Polski](README.pl.md)

# M365 MFA Administration Tool

Con esta herramienta, los administradores y el personal del servicio de asistencia configuran la **autenticación multifactor (MFA) en nombre de otros usuarios**, por ejemplo una llave FIDO2, una tarjeta TOTP o un código de acceso temporal. Además, muestra de un vistazo lo bien protegida que está una cuenta de usuario.

> [!NOTE]
> Las capturas de pantalla muestran la interfaz en inglés. Puede cambiar la interfaz a español en la parte superior derecha.

![Ventana principal de M365 MFA Administration Tool](images/en/main-window.png)

## Contenido

- [De un vistazo](#de-un-vistazo)
- [Inicio rápido](#inicio-rápido)
- [Guía paso a paso](#guía-paso-a-paso)
- [¿Qué método usar y cuándo?](#qué-método-usar-y-cuándo)
- [Crear una cuenta de emergencia](#crear-una-cuenta-de-emergencia)
- [Preguntas frecuentes y solución de problemas](#preguntas-frecuentes-y-solución-de-problemas)
- [Seguridad](#seguridad)
- [Para administradores: requisitos y permisos](#para-administradores-requisitos-y-permisos)
- [Estructura del proyecto](#estructura-del-proyecto)
- [Añadir un idioma](#añadir-un-idioma)

---

## De un vistazo

| | Función |
|---|---|
| 🔍 | **Buscar usuarios** – por nombre, correo electrónico, UPN o ID de objeto |
| 🚦 | **Semáforo de MFA** – muestra al instante si una cuenta está bien, débilmente o nada protegida, con una recomendación |
| 👑 | **Roles de administrador** – muestra si el usuario tiene derechos administrativos |
| 📋 | **Ver y eliminar métodos MFA** – todos los métodos registrados con fecha y detalles |
| ➕ | **Configurar métodos** – llave FIDO2, tarjetas TOTP, Temporary Access Pass y MFA ficticia |
| 🆘 | **Cuenta de emergencia** – crear un acceso de emergencia (break-glass) con llave FIDO2 y contraseña desconocida |
| 🌐 | **Multilingüe** – inglés (predeterminado), alemán, español, francés, italiano, portugués, neerlandés y polaco |

---

## Inicio rápido

1. Copie la carpeta completa en su equipo (los archivos deben permanecer juntos).
2. **Haga doble clic en `Start.cmd`.**
3. En la parte superior derecha, cambie el idioma a **Español** y haga clic en **"Iniciar sesión"**. Inicie sesión con su propia cuenta de administrador.

> [!TIP]
> Para un acceso rápido, cree un acceso directo en el escritorio a `Start.cmd` (clic derecho → *Crear acceso directo*).

En el primer inicio de sesión, la herramienta comprueba si faltan componentes necesarios. Si es así, los enumera y pregunta una sola vez si deben instalarse; la instalación se ejecuta en segundo plano (uno o dos minutos) y se muestra en el registro. Después, Microsoft solicita una única vez el consentimiento para los permisos de la herramienta.

---

## Guía paso a paso

### 1. Elegir el idioma e iniciar sesión

La interfaz se inicia en **inglés**. Con el cuadro de selección en la parte superior derecha, junto a "Sign in", puede cambiar el idioma en cualquier momento, sin reiniciar. La selección se guarda para su usuario de Windows y se aplica en el siguiente inicio.

Haga clic en **"Iniciar sesión"** en la parte superior derecha. Tras iniciar sesión correctamente, aparece en verde *"Conectado como …"* junto con el inquilino. **"Cerrar sesión"** finaliza la sesión; esto también ocurre automáticamente al cerrar la ventana.

### 2. Buscar un usuario

En el cuadro **"1. Buscar usuario"**, escriba el comienzo de un nombre, una dirección de correo electrónico o el UPN y pulse **Intro** (o haga clic en **"Buscar"**).

- **Un resultado:** el usuario se abre directamente.
- **Varios resultados:** se despliega una lista debajo del cuadro de búsqueda; haga clic en el usuario deseado. Con **Esc** o un clic fuera, la lista se cierra.

### 3. Entender el estado de MFA

A la derecha, en **"Usuario seleccionado"**, el **semáforo de MFA** muestra lo bien protegida que está la cuenta:

| Semáforo | Significado | ¿Qué hacer? |
|---|---|---|
| 🟢 **MFA fuerte (resistente al phishing)** | Llave FIDO2, clave de acceso o Windows Hello presente | Todo correcto. |
| 🟢 **MFA fuerte** | App Authenticator o tarjeta/app TOTP presente | Correcto. Para administradores se recomienda además FIDO2. |
| 🟡 **Solo MFA débil** | Solo SMS o llamada | Configure un método mejor y después elimine SMS/llamada. |
| 🟡 **Solo MFA ficticia** | La cuenta está bloqueada como protección (ver [MFA ficticia](#qué-método-usar-y-cuándo)) | Configure un método real para poder usarla. |
| 🟡 **Solo Temporary Access Pass** | Solo un código de acceso temporal | El usuario debe usarlo ahora para configurar un método permanente. |
| 🔴 **Sin MFA – solo contraseña** | Sin segundo factor | Configure un método con urgencia. |

Debajo del semáforo aparecen recomendaciones concretas, por ejemplo *"También hay SMS/llamada registrados y se pueden eliminar"*.

Más abajo, **"Roles administrativos"** muestra si el usuario tiene derechos de administrador. Con **"Mostrar"** se despliega la lista. Para cada rol se indica también si está activo de forma permanente, asignado a través de un grupo o solo activable mediante PIM.

### 4. Ver y eliminar métodos MFA

A la izquierda, en **"2. Métodos MFA registrados"**, aparecen todos los métodos del usuario. Al hacer clic en un método se muestran debajo **todos los detalles** (p. ej. modelo de dispositivo, número de serie, fecha de creación).

Para eliminar un método, selecciónelo y haga clic en **"Eliminar método"**. Antes de eliminar aparece una confirmación. La contraseña no se puede eliminar.

> [!NOTE]
> Microsoft aplica los cambios con unos segundos de retraso. La herramienta espera automáticamente hasta que la lista muestre el estado nuevo. Si es necesario, haga clic en **"Actualizar"**.

### 5. Configurar un método nuevo

A la derecha, en **"3. Configurar método"**, seleccione el método deseado:

![Selección del método MFA](images/en/select-method.png)

Según el método, aparecen los campos correspondientes (p. ej. el número de serie) y una breve indicación. Después haga clic en **"Iniciar configuración"** y confirme. El resultado aparece en el **registro** y la lista de métodos se actualiza automáticamente.

---

## ¿Qué método usar y cuándo?

| Método | ¿Cuándo usarlo? | ¿Qué ocurre? |
|---|---|---|
| **Llave de seguridad FIDO2** | El usuario recibe una llave FIDO2 (p. ej. YubiKey). El método más seguro, especialmente para administradores. | Conecte la llave e introduzca el número de serie. Windows pide el **PIN** de la llave y que la **toque**. La llave se llamará `FIDO2-<número de serie>`. |
| **Tarjeta TOTP con secreto fijo** | El usuario recibe una tarjeta de códigos cuyo secreto suministró el fabricante. | Introduzca el número de serie y el secreto. La tarjeta se crea, se asigna al usuario y se activa de inmediato. |
| **Tarjeta TOTP programable** | El usuario recibe una tarjeta de códigos que se programa uno mismo (p. ej. con la app del fabricante). | Introduzca el número de serie. La herramienta genera un secreto nuevo y muestra el **código QR y el secreto**. Programe la tarjeta con ellos y cierre la vista con ✕. |
| **Temporary Access Pass (TAP)** | El usuario debe configurar él mismo Authenticator o una clave de acceso, pero aún no tiene ningún método, o lo ha perdido. | Se genera un código **válido desde ahora durante 2 horas** y de uso múltiple. Aparece en grande en un recuadro amarillo y se puede copiar. Un TAP existente se reemplaza. |
| **MFA ficticia** | Se quiere proteger una cuenta que (todavía) nadie usa, p. ej. una cuenta de emergencia o de servicio nueva. | Se registra un método de código cuya clave se destruye de inmediato. Al iniciar sesión se exige una MFA que nadie puede cumplir, lo que protege la cuenta. |

> [!IMPORTANT]
> **Los TAP, secretos y códigos QR se muestran una sola vez.** No se escriben en el registro y no se pueden recuperar más tarde. Si guarda un código QR con "Guardar código QR …", el archivo contiene el secreto: elimínelo después de programar.

---

## Crear una cuenta de emergencia

Una **cuenta de emergencia (break-glass)** es un acceso de emergencia que permite entrar en el inquilino aunque los accesos de administrador normales fallen (p. ej. por una directiva de acceso condicional errónea).

Haga clic en **"Cuenta de emergencia …"** en la parte superior derecha:

![Diálogo "Crear cuenta de emergencia"](images/en/breakglass-dialog.png)

1. Seleccione el **dominio** en el que se creará la cuenta.
2. Decida si la cuenta recibe el rol **Global Administrator** (recomendado, preseleccionado).
3. Conecte la **llave FIDO2** e introduzca su número de serie.
4. Haga clic en **"Crear cuenta"**.

A continuación, la herramienta automáticamente:

- crea la cuenta con una **contraseña aleatoria** (255 caracteres; nunca se muestra ni se guarda, nadie la conoce)
- cambia el nombre de la cuenta al ID de objeto único
- asigna el rol Global Administrator
- protege la cuenta de inmediato con **MFA ficticia**
- **registra la llave FIDO2** (Windows pide PIN y que la toque) y después vuelve a eliminar la MFA ficticia

Al final, un resumen muestra lo realizado y la nueva cuenta se muestra directamente.

> [!WARNING]
> **Después, complete manualmente:**
> - **Excluya** la cuenta **de todas las directivas de acceso condicional**.
> - Configure una **alerta de inicio de sesión** para detectar cualquier uso.
> - Guarde la llave FIDO2 en un lugar seguro (p. ej. una caja fuerte).

Si el registro de FIDO2 falla o se cancela, la cuenta sigue protegida con MFA ficticia. La llave se puede añadir más tarde en **"3. Configurar método → Llave de seguridad FIDO2"**.

---

## Preguntas frecuentes y solución de problemas

**Al hacer doble clic en `Start.cmd` no ocurre nada o aparece un error.**
La herramienta solo funciona en Windows. Si la carpeta se copió de Internet, Teams o un archivo ZIP, los archivos pueden estar bloqueados. Ejecute una vez en PowerShell dentro de la carpeta: `Get-ChildItem -Recurse | Unblock-File`.

**El inicio de sesión vuelve a pedir consentimiento.**
Es normal cuando una función nueva necesita permisos adicionales, por ejemplo con la primera cuenta de emergencia.

**Un método recién creado o eliminado no se muestra de inmediato.**
Microsoft necesita unos segundos. La herramienta espera automáticamente hasta unos 16 segundos; después, si es necesario, haga clic en **"Actualizar"**.

**FIDO2: "Fido credential policy …" o "no está habilitado".**
FIDO2 no está habilitado en el inquilino. Un administrador debe habilitarlo en la directiva de métodos de autenticación (ver [requisitos](#para-administradores-requisitos-y-permisos)).

**FIDO2: "El UPN es demasiado largo".**
FIDO2 permite un máximo de 64 caracteres para el nombre de inicio de sesión (UPN).

**Tarjeta TOTP: "Un token con el número de serie … ya está asignado a …".**
La tarjeta ya pertenece a otro usuario. Elimínela primero allí.

**Mensaje de error con "Authorization_RequestDenied" o "Forbidden".**
A su cuenta le falta un rol de administrador (ver [roles](#para-administradores-requisitos-y-permisos)).

Cada acción aparece con su hora en el **registro** de la parte inferior derecha. Además, se guarda de inmediato en un archivo de registro diario en la carpeta de la herramienta, p. ej. `Logs\2026-10-12.log` (si la carpeta no admite escritura: `%LOCALAPPDATA%\M365MfaTool\Logs`), útil en caso de consultas.

---

## Seguridad

- **Sin secretos en el registro:** los TAP, secretos y contraseñas nunca se registran ni se guardan en disco.
- **Contraseñas desconocidas:** las contraseñas de las cuentas de emergencia se generan aleatoriamente y nunca se muestran.
- **Confirmaciones:** cada cambio debe confirmarse; las confirmaciones tienen "No" como opción predeterminada.
- **Limpieza en caso de error:** si falla la configuración de una tarjeta TOTP, la herramienta elimina automáticamente las entradas creadas a medias.

> [!CAUTION]
> Realice acciones administrativas solo de acuerdo con su proceso interno de aprobación y seguridad.

---

## Para administradores: requisitos y permisos

### Requisitos del sistema

- Windows con **Windows PowerShell 5.1** (preinstalado; PowerShell 7 no es compatible porque la interfaz usa WPF)
- Acceso a Internet en el primer inicio para instalar los módulos de PowerShell (solo para el usuario actual, sin derechos de administrador):
  - `Microsoft.Graph.Authentication`
  - `Microsoft.Graph.Identity.SignIns` y `DSInternals.Passkeys` **1.0.6** (FIDO2)
  - `QRCodeGenerator` (códigos QR para tarjetas TOTP programables)

  También se pueden instalar de antemano con `Install-Prerequisites.ps1`.
- Para FIDO2, la llave debe estar conectada al **equipo local** (por RDP solo con redirección de WebAuthn).

### Permisos de Graph (delegados)

Al iniciar sesión:

| Permiso | Para qué |
|---|---|
| `User.Read.All` | Buscar usuarios |
| `UserAuthenticationMethod.Read.All` | Mostrar métodos MFA |
| `UserAuthenticationMethod.ReadWrite.All` | Configurar y eliminar métodos MFA |
| `Policy.ReadWrite.AuthenticationMethod` | Crear/eliminar tarjetas TOTP y MFA ficticia en el inventario de tokens |
| `RoleManagement.Read.Directory` | Mostrar los roles de administrador de un usuario |

Además, con la primera cuenta de emergencia:

| Permiso | Para qué |
|---|---|
| `User.ReadWrite.All` | Crear usuarios |
| `Domain.Read.All` | Mostrar dominios para seleccionar |
| `RoleManagement.ReadWrite.Directory` | Asignar Global Administrator |

### Roles de Entra necesarios para su propia cuenta

| Tarea | Rol |
|---|---|
| Gestionar métodos de usuarios normales, TAP | **Authentication Administrator** |
| Gestionar métodos de administradores | **Privileged Authentication Administrator** |
| Tarjetas TOTP y MFA ficticia | además **Authentication Policy Administrator** |
| Cuenta de emergencia | **Global Administrator** (o Privileged Role Administrator + User Administrator) |

### Configuración del inquilino

En la **directiva de métodos de autenticación** (Centro de administración de Entra → Protección → Métodos de autenticación) deben estar habilitados los métodos usados:

- **Clave de acceso (FIDO2)**
- **Tokens OATH de hardware** (para tarjetas TOTP y MFA ficticia)
- **Temporary Access Pass** – vigencia máxima de al menos 2 horas

### Notas

- Algunas funciones usan la **API beta** de Microsoft Graph (p. ej. para tokens OATH de hardware), que puede cambiar.
- Los roles elegibles mediante PIM solo se muestran con Entra ID P2.
- El idioma elegido se guarda en `%APPDATA%\M365MfaTool\settings.json`.

---

## Estructura del proyecto

| Archivo | Contenido |
|---|---|
| `Start.cmd` | Iniciador por doble clic |
| `Start-M365MfaTool.ps1` | Interfaz, gestión de estado y eventos |
| `UI/MainWindow.xaml` | Diseño de la ventana principal |
| `UI/BreakGlassDialog.xaml` | Diálogo para nuevas cuentas de emergencia |
| `Modules/Graph.psm1` | Inicio de sesión, solicitudes a Graph, usuarios, dominios, roles, semáforo de MFA, lectura/eliminación de métodos |
| `Modules/Provisioning.psm1` | Configuración de FIDO2, tarjetas TOTP, MFA ficticia, TAP y cuentas de emergencia |
| `Modules/Localization.psm1` | Multilingüismo: carga los archivos de idioma y proporciona los textos |
| `Languages/*.json` | Textos por idioma (`en.json` es la referencia) |
| `Install-Prerequisites.ps1` | Instalación previa opcional de todos los módulos |
| `docs/` | Documentación traducida y capturas de pantalla |
| `Logs/` | Archivos de registro diarios (se crean automáticamente, no se guardan en Git) |

---

## Añadir un idioma

1. Copie `Languages/en.json` y nómbrelo con el código del idioma, p. ej. `sv.json` para sueco.
2. Establezca `"_language"` con el nombre del idioma en ese idioma (p. ej. `"Svenska"`) y traduzca todos los textos. Los marcadores como `{0}` deben mantenerse.
3. Reinicie la herramienta: el idioma aparece automáticamente en la selección. Los textos que falten se muestran en inglés.
4. Opcional: añada una documentación traducida como `docs/README.<código>.md` y enlácela en la barra de idiomas de todos los archivos README.
