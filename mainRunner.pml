/* моделируем исполнение скрипта, начиная с run.
 по мере моделирования, будем дополнять модель другими процессами
 или просто расширять */
 
 /* enum State */
 #define ready 0
 #define starting 1
 #define stopping 2
 #define running 3

int mMaxScriptId = 0; /* поле mMaxScriptId в trikScriptRunner */
bool fileNameisEmpty = true; /* для файла, передаваемого в запуске TrikScriptRunner::run */
byte mState = ready; /* ScriptEngineWorker:state -> делать ли его локальным? */


/* Каким образом организовано помещение в поток ??? */
/* Каким образом смоделировать сигнал-слот? (Паттерн наблюдатель?) - синхронно? то есть если коннект 2 раза сделать, то как обходить будет сигнал? */
/* Может стоит на месте QLOG_INFO() писать printf() с выводом той же информации? получится ли так везде и есть ли это хорошая цель? */

mtype = {startedScript }; /* попробуем тут располагать сигналы! */

chan signals = [0] of {mtype, int}; /* пытаемся моделировать сигналы, если несколько коннектов, то несколько раз и вызываем !&? */

proctype mWorkerThread(int _scriptID) /* id скриптов нам полезны, вроде как */
{
	int mScriptId;
	mState = starting;
	mScriptId = _scriptID;
	signals ! startedScript, scriptId;
	
}

proctype GUIThread()
{
	
/* создаем объект */

//	: mScriptController(new ScriptExecutionControl())
//	connect(&mWorkerThread, SIGNAL(finished()), mScriptEngineWorker, SLOT(deleteLater()));
//	connect(&mWorkerThread, SIGNAL(finished()), &mWorkerThread, SLOT(deleteLater()));
//	mScriptEngineWorker->moveToThread(&mWorkerThread);

//	connect(mScriptEngineWorker, SIGNAL(completed(QString, int)), this, SIGNAL(completed(QString, int)));

//	connect(mScriptController.data(), SIGNAL(sendMessage(QString)), this, SIGNAL(sendMessage(QString)));

/* вызывается TrikScriptRunner::run */

	mMaxScriptId++;
	workerStopScript: skip; /* ScriptEngineWorker::stopScript - а если остановится? - надо поправить */
	/* удалил действия связанные с файлом, они не могут повлиять на модель - максимумум вызывается виджет */
	run mWorkerThread(mMaxScriptId - 1); /* в нем будет вызовы соответсвующие для ScriptEngineWorker */
	
	/* ниже переносим коннекты */
	int x;
	do
	:: signals ? startedScript, x;
		-> mSc
	
		if (scriptId == -1) {
		return;
	}

	} else {
		emit startedDirectScript(scriptId);
	}
	
	od
}

init 
{
	run GUIThread();
}