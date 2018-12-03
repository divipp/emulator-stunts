# Stunts Emulator

Emulated version of Stunts 4D Sports Driving in Haskell

### System Requirements
- OS: Windows/Linux/OSX
- Graphics: OpenGL 3.3 or better

## Setup

#### 1. On **Linux** install the following libraries.
   i.e. on Ubuntu:
   ```
   sudo apt install libgl1-mesa-dev libxi-dev libxcursor-dev libxinerama-dev libxrandr-dev zlib1g-dev libpulse-dev libalut-dev libopenal-dev
   ```
   For other Linux distributions make sure the corresponing packages are installed.

   *These libraries required for OpenGL development and OpenAL audio library.*

#### 2. Get restunts project

  ```
  svn co svn://anders-e.com/restunts/trunk/restunts
  ```

#### 3. Compile & Run

To compile you will need [Haskell Stack](https://docs.haskellstack.org/en/stable/README/).

```
stack setup
stack build
stack exec stuntsemulator
```
