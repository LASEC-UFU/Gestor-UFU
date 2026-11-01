VERSION 5.00
Begin {C62A69F0-16DC-11CE-9E98-00AA00574A4F} HorarioDisciplinaForm
   Caption         =   "Editor de Hor�rios das Disciplinas"
   ClientHeight    =   7920
   ClientLeft      =   120
   ClientTop       =   468
   ClientWidth     =   5676
   OleObjectBlob   =   "HorarioDisciplinaForm.frx":0000
   StartUpPosition =   1  'CenterOwner
End
Attribute VB_Name = "HorarioDisciplinaForm"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = False
Attribute VB_PredeclaredId = True
Attribute VB_Exposed = False
Option Explicit
Public discipinaTxt As String

Private Sub BEDisciplina_Click()
    Dim result() As String
    EdicaoDisciplina.LCurso.Caption = LCurso.Caption
    EdicaoDisciplina.LPeriodo.Caption = LPeriodo.Caption
    result = Split(CBDiscipina.Text, "_")
    EdicaoDisciplina.TCodigo.Value = result(0) 'C�digo
    EdicaoDisciplina.TNome.Value = result(1) 'Nome da Disciplina
    EdicaoDisciplina.TTurma.Value = result(2) 'Turma
    EdicaoDisciplina.TDocente.Value = result(3) 'Docente
    EdicaoDisciplina.TSala.Value = result(4) 'Sala
    EdicaoDisciplina.TSigla.Value = result(5) 'Sigla
    EdicaoDisciplina.Show
End Sub

Private Sub BEProfessores_Click()
    Dim result() As String
    CriarDisciplina.LCurso.Caption = LCurso.Caption
    CriarDisciplina.LPeriodo.Caption = LPeriodo.Caption
    result = Split(CBDiscipina.Text, "_")
    CriarDisciplina.TCodigo.Value = result(0) 'C�digo
    CriarDisciplina.TNome.Value = result(1) 'Nome da Disciplina
    CriarDisciplina.TTurma.Value = result(2) 'Turma
    CriarDisciplina.TDocente.Value = result(3) 'Docente
    CriarDisciplina.TSala.Value = result(4) 'Sala
    CriarDisciplina.TSigla.Value = result(5) 'Sigla
    CriarDisciplina.Show
End Sub

Private Sub BSair_Click()
    Unload Me
End Sub

Private Sub CBDiscipina_Change()
    ' Se opcaoDesejada = 1 apenas Carregar Formulario pois CombBox teve sua selec�o alterada
    ' Se opcaoDesejada = 2 apenas Salvar Mudan�as do CombBox no BDados
    ' Se opcaoDesejada = 3 apenas Preencher Planilha de Hor�rios
    ' Se opcaoDesejada = 4 apenas Preencher Disciplinas no CombBox
    Call BDados.preencherPeriodo(2, discipinaTxt, CInt(LPeriodo.Caption), LCurso.Caption)
    discipinaTxt = CBDiscipina.Text
    Call BDados.preencherPeriodo(1, CBDiscipina.Text, CInt(LPeriodo.Caption), LCurso.Caption)
    If Not CBDiscipina.Text Like "" Then
        BEDisciplina.Enabled = True
    Else
        BEDisciplina.Enabled = False
    End If
End Sub

Private Sub CAtualiza_Click()
    Call BDados.preencherPeriodo(2, discipinaTxt, CInt(LPeriodo.Caption), LCurso.Caption)
    Call BDados.preencherPeriodo(3, CBDiscipina.Text, CInt(LPeriodo.Caption), LCurso.Caption)
End Sub

Private Sub UserForm_Activate()
    discipinaTxt = ""
    Call BDados.preencherPeriodo(4, CBDiscipina.Text, CInt(LPeriodo.Caption), LCurso.Caption)
End Sub

Private Sub UserForm_Terminate()
    Call BDados.preencherPeriodo(2, discipinaTxt, CInt(LPeriodo.Caption), LCurso.Caption)
    Call BDados.preencherPeriodo(3, CBDiscipina.Text, CInt(LPeriodo.Caption), LCurso.Caption)
End Sub
