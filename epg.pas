{
This file is part of OvoM3U
Copyright (C) 2020 Marco Caselli

OvoPlayer is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

}
{$I codegen.inc}
unit epg;

interface

uses
  Classes, SysUtils, DateUtils, laz2_XMLRead, Laz2_DOM, sqlite3dyn, sqlite3conn, sqldb, um3uloader, BaseTypes;

type
  TEpg = class;
  { TEpgScanner }

  TEpgScanner = class(TThread)
  private
    XMLDoc: TXMLDocument;
    Root: tdomNode;
    fMrl: string;
    fOwner: TEpg;
    function FindChannelId(Channel: string): integer;
  protected
    procedure Execute; override;
    function Load(Channel: string): integer;
  public
    constructor Create(mrl: string; Owner: TEpg); reintroduce;
  end;

  TEpg = class
  private
    fDB: TSQLite3Connection;
    fEpgAvailable: boolean;
    fTR: TSQLTransaction;
    FOnScanComplete: TNotifyEvent;
    FOnScanStart: TNotifyEvent;
    fScanning: boolean;
    procedure AfterScan;
    procedure BeforeScan;
    procedure CheckDBStructure;
    procedure EndScan(AObject: TObject);
    function GetDbVersion: integer;
    procedure GetLogEvent(Sender: TSQLConnection; EventType: TDBEventType; const Msg: String);
    procedure SetLastScan(ScanType: string);
    procedure SetupDBConnection;
    procedure UpgradeDBStructure(LoadedDBVersion: integer);
  public
    property OnScanComplete: TNotifyEvent read FOnScanComplete write FOnScanComplete;
    property OnScanStart: TNotifyEvent read FOnScanStart write FOnScanStart;
    property EpgAvailable: boolean read fEpgAvailable;
    constructor Create;
    destructor Destroy; override;
    function LastScan(const ScanType: string): TDateTime;
    procedure LoadChannelList(List: TM3ULoader);
    procedure Scan;
    function GetEpgInfo(Channel: integer; CurrTime: TDateTime): REpgInfo;  overload;
    function GetEpgInfo(Channel: integer; StartTime: TDateTime; EndTime: TDateTime): AREpgInfo; overload;
  end;


implementation

uses GeneralFunc, Config, ZStream;

{ TEpg }
const
  PRAGMAS_COUNT = 3;
  PRAGMAS: array [1..PRAGMAS_COUNT] of string =
    (
    //            'PRAGMA locking_mode = EXCLUSIVE;',
    'PRAGMA temp_store = MEMORY;',
    'PRAGMA count_changes = 0;',
    'PRAGMA encoding = "UTF-8";'
    );
  CURRENTDBVERSION = 1;

  CREATECONFIGTABLE1 = 'CREATE TABLE config (' + '"Version" INTEGER COLLATE NOCASE' + ');';

  CREATECONFIGTABLE2 = ' INSERT INTO config (Version) VALUES(1);';
  UPDATECONFIG = 'UPDATE config SET Version = %d;';

  CREATESCANTABLE1 = 'CREATE TABLE scans (' + ' "Epg" DATETIME' + ' ,"Channels" DATETIME' + ');';
  CREATESCANTABLE2 = 'insert into  scans values  (0,v0);';

  CREATECHANNELTABLE = 'CREATE TABLE channels (' + ' "ID" INTEGER primary key' + ',"Name" VARCHAR COLLATE NOCASE' + ',"ChannelNo" VARCHAR COLLATE NOCASE' + ')';
  CREATECHANNELINDEX1 = 'CREATE INDEX "idx_Channels_Name" on channels (Name ASC);';

  CREATEPROGRAMMETABLE = 'CREATE TABLE programme (' + ' idProgram    integer primary key' + ',idChannel    integer' + ',sTitle       VARCHAR(128)' + ',sPlot        VARCHAR' + ',dStartTime   DATETIME' + ',dEndTime     DATETIME' + ');';
  CREATEPROGRAMMEINDEX1 = 'CREATE INDEX "idx_programme_Channel" on programme (idChannel, dStartTime ASC);';
  CREATEPROGRAMMEINDEX2 = 'CREATE INDEX "idx_programme_iStartTime" on programme (dStartTime ASC);';

  INSERTPROGRAMME = 'INSERT INTO "programme"("idProgram","idChannel","sTitle","sPlot","dStartTime","dEndTime")' + ' values  (NULL,:idChannel,:sTitle,:sPlot,:dStartTime,:dEndTime);';

procedure TEpg.GetLogEvent(Sender: TSQLConnection;
  EventType: TDBEventType; const Msg: String);
// The procedure is called by TSQLConnection and saves the received log messages
// in the FConnectionLog stringlist
var
  Source: string;
begin
  // Nicely right aligned...
  case EventType of
    detCustom:   Source:='Custom:  ';
    detPrepare:  Source:='Prepare: ';
    detExecute:  Source:='Execute: ';
    detFetch:    Source:='Fetch:   ';
    detCommit:   Source:='Commit:  ';
    detRollBack: Source:='Rollback:';
    else Source:='Unknown event. Please fix program code.';
  end;
  Writeln(Source + ' ' + Msg);
end;

procedure TEpg.SetupDBConnection;
var
  i: integer;
begin
  fDB := TSQLite3Connection.Create(nil);
  fDB.DatabaseName := GetConfigDir + 'epg.db';
//  fDB.LogEvents:=LogAllEvents;
//  fDB.OnLog:=GetLogEvent;

  ftr := TSQLTransaction.Create(nil);

  fTR.DataBase := fDB;

  for i := 1 to PRAGMAS_COUNT do
    fdb.ExecuteDirect(PRAGMAS[i]);

  fdb.Connected := True;

  fTR.Active := True;

end;

function TEpg.GetDbVersion: integer;
var
  TableList: TStringList;
  tmpQuery: TSQLQuery;
begin
  TableList := TStringList.Create;
  try
    fDB.GetTableNames(TableList, False);
    if TableList.IndexOf('Config') < 0 then
    begin
      Result := 1;
      fDB.ExecuteDirect(CREATECONFIGTABLE1);
      fDB.ExecuteDirect(CREATECONFIGTABLE2);
      ftr.CommitRetaining;
    end
    else
    begin
      tmpQuery := TSQLQuery.Create(fDB);
      tmpQuery.DataBase := fDB;
      tmpQuery.Transaction := fTR;
      tmpQuery.SQL.Text := 'SELECT Version FROM Config';
      tmpQuery.Open;
      Result := tmpQuery.Fields[0].AsInteger;
      tmpQuery.Free;
    end;
  finally
    TableList.Free;
  end;

end;

function TEpg.LastScan(const ScanType: string): TDateTime;
var
  tmpQuery: TSQLQuery;
begin
  try
    tmpQuery := TSQLQuery.Create(fDB);
    tmpQuery.DataBase := fDB;
    tmpQuery.Transaction := fTR;
    tmpQuery.SQL.Text := 'SELECT ' + ScanType + ' FROM Scans';
    tmpQuery.Open;
    if not tmpQuery.EOF then
      Result := tmpQuery.Fields[0].AsDateTime
    else
      Result := 0;

  finally
    tmpQuery.Free;
  end;

end;

procedure TEpg.SetLastScan(ScanType: string);
var
  tmpQuery: TSQLQuery;
begin
  try
    tmpQuery := TSQLQuery.Create(fDB);
    tmpQuery.DataBase := fDB;
    tmpQuery.Transaction := fTR;
    tmpQuery.SQL.Text := 'UPDATE scans set ' + ScanType + ' =:date';
    tmpQuery.parambyname('date').AsDateTime := now;
    tmpQuery.ExecSQL;
    fTR.CommitRetaining;
  finally
    tmpQuery.Free;
  end;

end;


procedure TEpg.CheckDBStructure;
var
  TableList: TStringList;
  LoadedDBVersion: integer;
begin
  TableList := TStringList.Create;
  try
    fDB.GetTableNames(TableList, False);
    if TableList.IndexOf('config') < 0 then
    begin
      fDB.ExecuteDirect(CREATECONFIGTABLE1);
      fDB.ExecuteDirect(CREATECONFIGTABLE2);
      fDB.ExecuteDirect(format(UPDATECONFIG, [CURRENTDBVERSION]));
      ftr.CommitRetaining;
    end;
    if TableList.IndexOf('scans') < 0 then
    begin
      fDB.ExecuteDirect(CREATESCANTABLE1);
      fDB.ExecuteDirect(CREATESCANTABLE2);
      ftr.CommitRetaining;
    end;
    if TableList.IndexOf('channels') < 0 then
    begin
      fDB.ExecuteDirect(CREATECHANNELTABLE);
      fDB.ExecuteDirect(CREATECHANNELINDEX1);
      ftr.CommitRetaining;
    end;
    if TableList.IndexOf('programme') < 0 then
    begin
      fDB.ExecuteDirect(CREATEPROGRAMMETABLE);
      fDB.ExecuteDirect(CREATEPROGRAMMEINDEX1);
      fDB.ExecuteDirect(CREATEPROGRAMMEINDEX2);
      ftr.CommitRetaining;
    end;

  finally
    TableList.Free;
  end;

  LoadedDBVersion := GetDbVersion;
  if LoadedDBVersion < CURRENTDBVERSION then
    UpgradeDBStructure(LoadedDBVersion);

end;

procedure TEpg.UpgradeDBStructure(LoadedDBVersion: integer);
begin

end;

procedure TEpg.EndScan(AObject: TObject);
begin

  AfterScan;

  if Assigned(FOnScanComplete) then
    FOnScanComplete(Self);

  fScanning := False;
end;

procedure TEpg.BeforeScan;
begin

  fDB.ExecuteDirect('delete from programme');

end;

procedure TEpg.AfterScan;
begin
  fTR.CommitRetaining;
end;


procedure TEpg.Scan;
var
  Scanner: TEpgScanner;
begin
  if LastScan('epg') + 12 > now then
    exit;

  if Assigned(FOnScanStart) then
    FOnScanStart(self);
  BeforeScan;
  Scanner := TEpgScanner.Create(Configobj.M3UProperties.EPGUrl, self);
  Scanner.OnTerminate := EndScan;
  Scanner.Start;
end;

function TEpg.GetEpgInfo(Channel: integer; CurrTime: TDateTime): REpgInfo;
var
  qSearch: TSQLQuery;
begin
  qSearch := TSQLQuery.Create(fDB);
  try
    qSearch.Transaction := fTR;
    qSearch.SQL.Text := 'select * from programme p where p.idChannel = :id  ' + ' and dStartTime < :time and dEndTime > :time ';
    qSearch.ParamByName('id').AsInteger := Channel;
    qSearch.ParamByName('time').AsDateTime := CurrTime;
    qSearch.Open;
    if qSearch.EOF then
      Result := Default(REpgInfo)
    else
    begin
      Result.Title := qSearch.FieldByName('sTitle').AsString;
      Result.Plot := qSearch.FieldByName('sPlot').AsString;
      Result.StartTime := qSearch.FieldByName('dStartTime').AsDateTime;
      Result.EndTime := qSearch.FieldByName('dEndTime').AsDateTime;
    end;
  finally
    qSearch.Free;
  end;

end;

function TEpg.GetEpgInfo(Channel: integer; StartTime: TDateTime; EndTime: TDateTime): AREpgInfo;
var
  qSearch: TSQLQuery;
  i: Integer;
begin
  qSearch := TSQLQuery.Create(fDB);
  try
    qSearch.Transaction := fTR;
    qSearch.SQL.Text := 'select distinct * from programme p where p.idChannel = :id  ' +
                        ' and ((dStartTime >= :stime and dEndTime <= :etime) ' +
                        '  or  (dStartTime <= :stime and dEndTime >= :stime) '+
                        '  or  (dStartTime <= :etime and dEndTime >= :etime)) ' +
                        ' order by dStartTime';
    qSearch.ParamByName('id').AsInteger := Channel;
    qSearch.ParamByName('stime').AsDateTime := StartTime;
    qSearch.ParamByName('etime').AsDateTime := EndTime;
    qSearch.Open;
    SetLength(Result, qSearch.RecordCount);
    i:=0;
    While not qSearch.EOF do
    begin
      Result[i].Title := qSearch.FieldByName('sTitle').AsString;
      Result[i].Plot := qSearch.FieldByName('sPlot').AsString;
      Result[i].StartTime := qSearch.FieldByName('dStartTime').AsDateTime;
      Result[i].EndTime := qSearch.FieldByName('dEndTime').AsDateTime;
      inc(i);
      qsearch.next;
    end;
  finally
    qSearch.Free;
  end;

end;


constructor TEpg.Create;
begin
  SetupDBConnection;
  CheckDBStructure;
end;

procedure TEpg.LoadChannelList(List: TM3ULoader);
var
  item: TM3UItem;
  qinsert: TSQLQuery;
begin
  qinsert := TSQLQuery.Create(fDB);
  try
    fdb.ExecuteDirect('delete from channels;');
    qinsert.Transaction := fTR;
    qinsert.SQL.Text := 'insert into channels values (null, :name, :ChannelNo);';
    for item in List do
    begin
      qinsert.ParamByName('name').AsString := item.Title;
      qinsert.ParamByName('ChannelNo').AsInteger := item.Number;
      qinsert.ExecSQL;
    end;
  finally
    qinsert.Free;
  end;
  fTR.CommitRetaining;

end;

destructor TEpg.Destroy;
begin
  ftr.Commit;
  fDB.Transaction := nil;
  fDB.Connected := False;
  fTR.Free;
  fDB.Free;
  inherited Destroy;
end;

{ TEpgScanner }

procedure TEpgScanner.Execute;
var
  CacheDir: string;
  ListName: string;
  Decompress: TGZFileStream;
  FcacheFile: TFileStream;

begin

  CacheDir := GetCacheDir;
  try
    DownloadFromUrl(fmrl, CacheDir + 'current-epg.gz');
    ListName := CacheDir + 'current-epg.gz';
    Decompress := TGZFileStream.Create(ListName, gzopenread);
    ListName := CacheDir + 'current-epg.xml';
    FcacheFile := TFileStream.Create(ListName, fmOpenWrite or fmcreate);
    Decompress.Position := 0;
    FcacheFile.CopyFrom(Decompress, 0);
    FcacheFile.Free;
    Load(ListName);
    fOwner.setlastscan('epg');
  except
    on e: Exception do
      WriteLn(e.message);
  end;
end;

function TEpgScanner.FindChannelId(Channel: string): integer;
var
  qFind: TSQLQuery;
begin
  qFind := TSQLQuery.Create(fOwner.fDB);
  try
    qFind.Transaction := fOwner.fTR;
    qFind.SQL.Text := 'select id from Channels where name = :name;';
    qFind.ParamByName('name').AsString := Channel;
    qFind.Open;
    if qFind.EOF then
      Result := -1
    else
      Result := qFind.Fields[0].AsInteger;

  finally
    qFind.Free;
  end;
end;

function TEpgScanner.Load(Channel: string): integer;
var
  i: integer;
  CurrNode: TDOMNode;
  fname: DOMString;
  OldName: string;
  s1, s2: TDateTime;
  idChannel: integer;
  qInsert: TSQLQuery;

  function NodeValue(const ValueName: string): string; inline;
  var
    tmpnode: TDOMNode;
  begin
    tmpnode := CurrNode.FindNode(ValueName);
    if Assigned(tmpnode) then
      Result := tmpnode.TextContent
    else
      Result := EmptyStr;
  end;

begin
  ReadXMLFile(XMLDoc, Channel);
  Root := XMLDoc.FindNode('tv');
  //  writeln(Root.NodeName, '  ', Root.ChildNodes.Count);
  OldName := '';
  idChannel := -1;
  qInsert := TSQLQuery.Create(fOwner.Fdb);
  qInsert.Transaction := fOwner.fTR;
  qInsert.SQL.Text := INSERTPROGRAMME;

  for i := 0 to Root.ChildNodes.Count - 1 do
  begin
    CurrNode := Root.ChildNodes.Item[i];
    //      writeln(currnode.NodeName);
    if CurrNode.NodeName <> 'programme' then
      Continue;
    fname := CurrNode.Attributes.GetNamedItem('channel').NodeValue;
    if fname <> OldName then
      idChannel := FindChannelId(fname);

    if idChannel <> -1 then
    begin
      qInsert.ParamByName('idchannel').AsInteger := idChannel;
      qInsert.ParamByName('sTitle').AsString := NodeValue('title');
      qInsert.ParamByName('sPlot').AsString := NodeValue('desc');
      s1 := EpgDateToDate(CurrNode.Attributes.GetNamedItem('start').NodeValue);
      s2 := EpgDateToDate(CurrNode.Attributes.GetNamedItem('stop').NodeValue);
      qInsert.ParamByName('dStartTime').AsDateTime := s1;
      qInsert.ParamByName('dEndTime').AsDateTime := s2;
      qInsert.ExecSQL;
    end;
  end;

end;

constructor TEpgScanner.Create(mrl: string; Owner: TEpg);
begin
  inherited Create(False);
  fOwner := Owner;
  fMrl := mrl;
end;

end.