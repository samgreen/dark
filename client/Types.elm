module Types exposing (..)

-- builtin
import Dict exposing (Dict)
import Http
import Dom
import Navigation
import Mouse

-- libs
import Keyboard.Event exposing (KeyboardEvent)

type alias Exception =
  { short : String
  , long : String
  , tipe : String
  , actual : String
  , actualType : String
  , result : String
  , resultType : String
  , expected : String
  , info : Dict String String
  , workarounds : List String }

type Tipe = TInt
          | TStr
          | TChar
          | TBool
          | TFloat
          | TObj
          | TList
          | TAny
          | TBlock
          | TOpaque
          | TNull
          | TIncomplete

-- There are two coordinate systems. Pos is an absolute position in the
-- canvas. Nodes and Edges have Pos'. VPos is the viewport: clicks occur
-- within the viewport and we map Absolute positions back to the
-- viewport to display in the browser.
type alias Pos = {x: Int, y: Int }
type alias VPos = {vx: Int, vy: Int }

type alias MouseEvent = {pos: VPos, button: Int}
type alias IsLeftButton = Bool

-- Placeholder for whatever the new "Node" is
type alias LiveValue = Int
type alias Special = Int
type HID = HID Int
type TLID = TLID Int

type EntryCursor = Creating Pos
                 | Filling TLID HID

type alias IsReentering = Bool
type alias HasMoved = Bool
type State = Selecting TLID HID
           | Entering IsReentering EntryCursor
           | Dragging VPos HasMoved State
           | Deselected

type Msg
    = GlobalClick MouseEvent
    | ToplevelClickDown Toplevel MouseEvent
    -- we have the actual node when NodeClickUp is created, but by the time we
    -- use it the proper node will be changed
    | ToplevelClickUp TLID MouseEvent
    | DragToplevel TLID Mouse.Position
    | EntryInputMsg String
    | EntrySubmitMsg
    | GlobalKeyPress KeyboardEvent
    | FocusEntry (Result Dom.Error ())
    | FocusAutocompleteItem (Result Dom.Error ())
    | RPCCallBack Focus (List RPC) (Result Http.Error (List Toplevel))
    | SaveTestCallBack (Result Http.Error String)
    | LocationChange Navigation.Location
    | AddRandom
    | ClearGraph
    | SaveTestButton
    | Initialization

type Focus = FocusNothing -- deselect
           | Refocus TLID
           | FocusExact TLID
           | FocusNext TLID
           | FocusSame -- unchanged

type RPC
    = NoOp
    | SetAST TLID Pos Expr
    | DeleteAll
    | Savepoint
    | Undo
    | Redo

type alias Autocomplete = { functions : List Function
                          , completions : List AutocompleteItem
                          , index : Int
                          , value : String
                          , open : Bool
                          , liveValue : Maybe LiveValue
                          , tipe : Maybe Tipe
                          }

type AutocompleteItem = ACFunction Function
                      | ACField String
                      -- | ACVariable Variable

type VariantTest = StubVariant



type alias Class = String
type Element = Leaf (Maybe HID, Class, String)
             | Nested Class (List Element)

type alias VarName = String
type alias FnName = String

type Expr = If Expr Expr Expr
          | FnCall FnName (List Expr)
          | Variable VarName
          -- let x1 = expr1; x2 = expr2 in expr3
          | Let (List (VarName, Expr)) Expr
          | Lambda (List VarName) Expr
          | Value String
          | Hole HID

type alias AST = Expr

type alias Toplevel = { id : TLID
                      , pos : Pos
                      , ast : AST
                      }

type alias Model = { center : Pos
                   , error : Maybe String
                   , lastMsg : Msg
                   , lastMod : Modification
                   , tests : List VariantTest
                   , complete : Autocomplete
                   , state : State
                   , toplevels : List Toplevel
                   }

type AutocompleteMod = ACSetQuery String
                     | ACAppendQuery String
                     | ACOpen Bool
                     | ACReset
                     | ACClear
                     | ACComplete String
                     | ACSelectDown
                     | ACSelectUp
                     | ACFilterByLiveValue LiveValue
                     -- | ACFilterByParamType Tipe NodeList

type Modification = Error String
                  | ClearError
                  | Select TLID HID
                  | Deselect
                  | SetToplevels (List Toplevel)
                  | Enter IsReentering EntryCursor
                  | RPC (List RPC, Focus)
                  | SetCenter Pos
                  | NoChange
                  | MakeCmd (Cmd Msg)
                  | AutocompleteMod AutocompleteMod
                  | Many (List Modification)
                  | Drag VPos HasMoved State
                  | SetState State

-- name, type optional
type alias Parameter = { name: String
                       , tipe: Tipe
                       , block_args: List String
                       , optional: Bool
                       , description: String
                       }

type alias Function = { name: String
                      , parameters: List Parameter
                      , description: String
                      , returnTipe: Tipe
                      }

type alias FlagParameter = { name: String
                           , tipe: String
                           , block_args: List String
                           , optional: Bool
                           , description: String
                           }

type alias FlagFunction = { name: String
                          , parameters: List FlagParameter
                          , description: String
                          , return_type: String
                          }



type alias Flags =
  { editorState: Maybe Editor
  , complete: List FlagFunction
  }

-- Values that we serialize
type alias Editor = { }

