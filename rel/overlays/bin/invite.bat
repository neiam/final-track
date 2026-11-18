@echo off
rem Set INVITE_EMAIL, INVITE_NOTE, INVITE_DAYS and INVITE_BY in the environment first.
call "%~dp0\final_track" eval FinalTrack.Release.invite
