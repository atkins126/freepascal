{$ifdef FPC}
  {$mode objfpc}
{$else}
  {$apptype console}
{$endif}

uses
{$ifndef FPC}
  Windows,
{$endif FPC}
{$ifdef unix}
  cthreads,
{$endif unix}
  SysUtils, Classes;

type
  TOperation = (opAdd, opDec, opExchange, opExchangeAdd, opExchangeDec, opCompareExchange);

  TWorker = class(TThread)
  private
    FOp: TOperation;
    FCount: longint;
    FOption: longint;
  protected
    procedure Execute; override;
  public
    constructor Create(ACount: longint; AOp: TOperation; AOption: longint = 0);
  end;

//{$define TEST_BROKEN_IMPLEMENTATION}

const
  TotalThreadCount = 50;
  TestCount = 1000000;
  WaitTime = 60;

var
  Counter, Counter2, Counter3: longint;
  WorkingCount: longint;
  AbortThread: boolean;
  LastCompareVal: longint;

{$ifndef FPC}
{$ifndef TEST_BROKEN_IMPLEMENTATION}
function InterlockedCompareExchange(var Target: longint; NewValue: longint; Comperand: longint): longint;
begin
  Result:=longint(Windows.InterlockedCompareExchange(pointer(Target), pointer(NewValue), pointer(Comperand)));
end;
{$endif TEST_BROKEN_IMPLEMENTATION}

procedure  ThreadSwitch;
begin
  Sleep(0);
end;
{$endif FPC}

{$ifdef TEST_BROKEN_IMPLEMENTATION}
function InterlockedCompareExchange(var Target: longint; NewValue: longint; Comperand: longint): longint;
begin
  Result:=Target;
  if Result = Comperand then
    Target:=NewValue;
end;
{$endif TEST_BROKEN_IMPLEMENTATION}

procedure CheckResult(check, expected, code: longint; const Msg: string);
begin
  if check <> expected then begin
    writeln(Msg, ' Result: ', check, '; Expected: ', expected);
    Halt(code);
  end;
end;

constructor TWorker.Create(ACount: longint; AOp: TOperation; AOption: longint);
begin
  FCount:=ACount;
  FOp:=AOp;
  FOption:=AOption;
  inherited Create(True);
  FreeOnTerminate:=True;
  if FOp = opCompareExchange then
    Priority:=tpHighest;
end;

procedure TWorker.Execute;
var
  i, j, k, opt: longint;
  t: TDateTime;
begin
  InterLockedIncrement(WorkingCount);
  Sleep(10);

  case FOp of
    opAdd:
      begin
        for i:=1 to FCount do begin
          InterLockedIncrement(Counter);
          if AbortThread then
            break;
        end;
      end;
    opDec:
      begin
        for i:=1 to FCount do begin
          InterLockedDecrement(Counter);
          if AbortThread then
            break;
        end;
      end;
    opExchange:
      begin
        for i:=1 to FCount do begin
          j:=InterLockedExchange(Counter, 10);
          InterLockedExchangeAdd(Counter, j - 10);
          if AbortThread then
            break;
        end;
      end;
    opExchangeAdd:
      begin
        for i:=1 to FCount do begin
          InterLockedExchangeAdd(Counter, 3);
          if AbortThread then
            break;
        end;
      end;
    opExchangeDec:
      begin
        for i:=1 to FCount do begin
          InterLockedExchangeAdd(Counter, -3);
          if AbortThread then
            break;
        end;
      end;
    opCompareExchange:
      begin
        opt:=FOption and 1;
        for i:=1 to FCount do begin
          t:=Now;
          j:=0;
          while not AbortThread do begin
            k:=InterLockedCompareExchange(Counter3, FOption, opt);
            if k = opt then
              break;
            if (k < 0) or (k >= LastCompareVal) then begin
              writeln('InterLockedCompareExchange. Invalid return value (', k, ').');
              Halt(10);
            end;
            Inc(j);
            if j and $F = 0 then
              ThreadSwitch;
            if j and $FFFF = 0 then begin
              if Now - t >= 30/SecsPerDay then begin
                writeln('InterLockedCompareExchange seems to be broken.');
                Halt(12);
              end;
              Sleep(1);
            end;
          end;
          if AbortThread then
            break;
          ThreadSwitch;
          k:=InterLockedExchange(Counter3, opt xor 1);
          if k <> FOption then begin
            writeln('InterLockedCompareExchange seems to be broken (', k, ').');
            Halt(11);
          end;
          InterLockedIncrement(Counter2);
        end;
      end;
  end;

  InterLockedDecrement(WorkingCount);
end;

procedure Run;
var
  i, j, k, CmpCount: longint;
  t: TDateTime;
  workers: array[0..TotalThreadCount - 1] of TWorker;
begin
  Counter:=0;
  Counter2:=0;
  Counter3:=0;
  CmpCount:=TestCount div 1000;
  writeln('Creating threads...');
  j:=0;
  k:=2;
  repeat
    i:=j;
    workers[j]:=TWorker.Create(TestCount, opAdd);
    Inc(j);
    workers[j]:=TWorker.Create(TestCount, opDec);
    Inc(j);
    workers[j]:=TWorker.Create(TestCount div 3, opExchange);
    Inc(j);
    workers[j]:=TWorker.Create(TestCount, opExchangeAdd);
    Inc(j);
    workers[j]:=TWorker.Create(TestCount, opExchangeDec);
    Inc(j);
    workers[j]:=TWorker.Create(CmpCount, opCompareExchange, k);
    Inc(j);
    Inc(k);
    workers[j]:=TWorker.Create(CmpCount, opCompareExchange, k);
    Inc(j);
    Inc(k);
  until j + (j - i) > TotalThreadCount;
  LastCompareVal:=k;
  writeln('Created ',j ,' threads.');

  writeln('Starting threads...');
  t:=Now;
  for i:=0 to j - 1 do begin
    workers[i].Suspended:=False;
    if Now -  t > 5/SecsPerDay then begin
      writeln('Threads start takes too long to complete.');
      Halt(4);
    end;
  end;

  writeln('Waiting for threads to complete...');
  Sleep(10);
  t:=Now;
  while WorkingCount <> 0 do begin
    if Now -  t > WaitTime/SecsPerDay then begin
      if AbortThread then begin
        writeln('Unable to abort threads.');
        Halt(3);
      end
      else begin
        AbortThread:=True;
        writeln('Timeout has expired. Active threads left: ', WorkingCount);
        t:=Now;
      end;
    end;
    Sleep(10);
  end;

  if AbortThread then begin
    writeln('The execution is too slow (', Counter2, ').');
    Halt(2);
  end;

  t:=Now - t;
  if t = 0 then
    t:=1/MSecsPerDay;

  CheckResult(Counter, 0, 1, 'Counter error:');

  CheckResult(Counter2, (LastCompareVal - 2)*CmpCount, 4, 'Counter2 error:');

  writeln('Test OK.');
  writeln('InterLockedCompareExchange: ', Round(Counter2/(t*SecsPerDay)), ' ops/sec.');
end;

begin
  Run;
end.
