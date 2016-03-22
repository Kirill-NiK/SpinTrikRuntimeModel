//#define NO_LOGGING // только для QLOG_INFO()
#define S 50 // максимальное количество запущенных скриптов (engineThreads)
#define N 100 // максимальная длина очереди event-ов для каждого потока

#ifndef NO_LOGGING
 #define LOG(x) printf(x)
#else
 #define LOG(x) skip
#endif

mtype {emptyEvent, INVOKEdoRun, completed, start, INVOKABLEstartThread, stopRunning }; /* используемые сигналы-события для всех потоков, параметры - в глобальные переменные */
// может описывать сигналы?
chan GUIThreadEvents = [N] of {mtype};
   
chan scriptWorkerThreadEvents = [N] of {mtype};

chan engineThreadEvents = [N] of {mtype}; // надо сделать матрицу SxN, соответсвенно поправить сигнал в нужный thread при emits

chan connectionThreadEvents = [N] of {mtype};

chan sensorsThreadEvents = [N] of {mtype};

byte mThreadCount = 0;

bool inEventDrivenMode = false; /* mThreading.inEventDrivenMode() */
bool stopRunningIsEmitted[S] = false; // удалить?

inline emit(thread, signal) /* в очередь событий \a thread добавить сигнал (событие) \a signal */
{
	assert(nfull(thread)); /* Если копятся ивенты, значит что-то пошло не так... */
	thread ! signal;
}

proctype sensorsThread() /* На самом деде существует много отдельных потоков для различных сенсоров */
{
	mtype signal;
	progress: do
	:: sensorsThreadEvents ? signal ->
		if
		:: signal == emptyEvent -> skip;
	    fi;
	od;
}

proctype connectionThread()
{
	mtype signal;
	progress: do
	:: connectionThreadEvents ? signal ->
		if
		:: signal == emptyEvent -> skip;
	    fi;
	od;
}

proctype engineThread()
{
	assert(_pid <= S); /* Изначально мы считаем, что максимальное количество запущенных потоков engineThread ограничено */ // - _pid - не для всей модели? 
	mtype signal;
	progress: do
	:: engineThreadEvents ? signal ->
		if
		:: signal == emptyEvent -> skip;
		:: signal == start -> /* ScriptThread::run() */
			LOG("Started thread ScriptThread");
			evaluate_call: skip; /* mEngine->evaluate(mScript) */
			emit(scriptWorkerThreadEvents, INVOKABLEstartThread); /* скрипт внутри может вызвать новые потоки, убивать... */
			// сделать соответствующий недетерминированный выбор, только с ограничением на вызов
			evaluate_return: skip;
			if
			:: true -> LOG("Uncaught exception at line");
			:: skip; // inEventDrivenMode -> emit(engineThreadEvents, stopRunning); stopRunningIsEmitted[_pid]; поставить проверку, что сигнал словлен, без этого не пускать.
			:: !inEventDrivenMode -> skip;
			fi;
			// mEngine->deleteLater(). можно послать соответствующий сигнал. который на обработке просто поставит метку deleted.
			LOG("Finishing thread id");
			// тут мьютексы
			LOG("Thread id has finished, thread object ...");
			atomic {mThreadCount--};
			if
			:: skip; // Threading::reset();
			:: skip;
			fi;
			LOG("Ended evaluation, thread ScriptThread");
	    fi;
	od;
}

proctype scriptWorkerThread()
{
	mtype signal;
	progress: do
	:: scriptWorkerThreadEvents ? signal ->
		if 
	    :: signal == emptyEvent -> skip;
		:: signal == INVOKEdoRun -> 
			startThread_call: skip;
			if
			:: LOG("Threading: can't start new thread due to reset"); goto startThread_return;
			:: skip;
			fi;
			if 
			:: LOG("Threading: attempt to create a thread which must be killed"); goto startThread_return;
			:: skip;
			fi;
			if
			:: LOG("Threading: attempt to create a thread which must be killed"); goto startThread_return;
			:: skip;
			fi;
			LOG("Starting new thread with engine");
			atomic {mThreadCount++;
				assert(mThreadCount <= S); /* Изначально мы считаем, что максимальное количество запущенных потоков engineThread ограничено */
				run engineThread();
				emit(engineThreadEvents, start);}; /* Мы переопределяли run(), поэтому отдельно расписываем thread->start() */
			LOG("Threading: started thread with engine thread object");
			startThread_return: skip;
			waitForAll_call: skip;
			mThreadCount == 0 ->
			waitForAll_return: skip;
			LOG("ScriptEngineWorker: evaluation ended with message, empty or error");
			emit(GUIThreadEvents, completed);
		fi;
		:: signal  == INVOKABLEstartThread ->
			startThread_call_: skip;
			if
			:: LOG("Threading: can't start new thread due to reset"); goto startThread_return;
			:: skip;
			fi;
			if 
			:: LOG("Threading: attempt to create a thread which must be killed"); goto startThread_return;
			:: skip;
			fi;
			if
			:: LOG("Threading: attempt to create a thread which must be killed"); goto startThread_return;
			:: skip;
			fi;
			LOG("Starting new thread with engine");
			atomic {mThreadCount++;
				assert(mThreadCount <= S); /* Изначально мы считаем, что максимальное количество запущенных потоков engineThread ограничено */
				run engineThread();
				emit(engineThreadEvents, start);}; /* Мы переопределяли run(), поэтому отдельно расписываем thread->start() */
			LOG("Threading: started thread with engine thread object");
			startThread_return_: skip;
	od;
}

proctype GUIThread()
{
	mtype signal;
	progress: do
	:: GUIThreadEvents ? signal -> /* расписываем ВСЕ возможные сигналы */
		if
		:: signal == emptyEvent -> 
			LOG("TrikGui started");
			run connectionThread(); /* создается с backgroundwidget */
			run sensorsThread(); /* создается с brick */
			LOG("Starting TrikScriptRunner worker thread");
			run scriptWorkerThread();
			/* TrikScriptRunner::run */
			LOG("TrikScriptRunner: new script");
			/* вызывается mScriptEngineWorker->stopScript() */
			LOG("ScriptEngineWorker: stopping script");
			if
			:: LOG("ScriptEngineWorker : ending interpretation");
			:: skip;
			fi;
			LOG("Threading: reset started");
			LOG("Threading: reset ended");
			LOG("ScriptEngineWorker: stopping complete");
			/* startScriptEvaluation */
			LOG("ScriptEngineWorker: starting script");
			emit(scriptWorkerThreadEvents, INVOKEdoRun);
		:: signal == completed ->
			if
			:: true -> hideRunningWidgetSignal: skip;
			:: true-> sendMessages: skip; showErrorSignal: skip; /* по всем открытым соединениям вещается об ошибке */
			fi;
			LOG("Stopping brick");
			brikReset: skip; /* остановка по всем сенсорам, дисплею...*/
			do // должно дополняться любыми INVOKE-ами, отправленными к GUIWorker-у
			 // :: перебираем все ивенты в лупе и посылаем обратно. заводим счетчик до 0. если сигналы определенного типа, не посылаем, но уменьшаем счетчик. 
			:: break; // если счетчик равняется 0
			od;
	    fi;
	od;
}

init
{
	run GUIThread();
	emit(GUIThreadEvents, emptyEvent);
}