% HGM:
% - Does endian-ness matter? How to make robust?
% - Consider non-doubles for efficiency/speed/memory
% - What's the difference between the "length" of a message as provided by FMT, vs the sum of the lengths of the field identifiers? (BQNnz, for example)
%
% This is hard-coded:
% - The 128 (FMT) message must have fields "Name", "Type", and "Length" which specify other LogMsgGroups
% - The FMT message data is 86 bytes long. (TODO HGM: un-hard-code this)

classdef Ardupilog < dynamicprops & matlab.mixin.Copyable
    properties (Access = public)
        fileName % name of .bin file
        filePathName % path to .bin file
        % platform
        % version
        % bootTime
        numMsgs
    end
    properties (Access = private)
        fileID = -1;
        lastLineNum = 0;
        header = [163 149]; % Message header as defined in ArduPilot
        log_data = char(0); % The .bin file data as a row-matrix of chars (uint8's)
        log_data_read_ndx = 0; % The index of the last byte processed from the data
        wb_handle; % Handle to the waitbar, used to delete it in case of error
        fmt_cell = cell(0); % a local copy of the FMT info, to reduce run-time
        fmt_type_mat = []; % equivalent to cell2mat(obj.fmt_cell(:,1)), to reduce run-time
    end %properties
    
    methods
        function obj = Ardupilog(pathAndFileName)
            if nargin == 0
                % If constructor is empty, prompt user for log file
                [filename, filepathname, ~] = uigetfile('*.bin','Select binary (.bin) log-file');
                obj.fileName = filename;
                obj.filePathName = filepathname;
            else
                % Use user-specified log file
                [filepathname, filename, extension] = fileparts(which(pathAndFileName));
                obj.filePathName = filepathname;
                obj.fileName = [filename, extension];
            end

            % If user pressed "cancel" then return without trying to process
            if all(obj.fileName == 0) && all(obj.filePathName == 0)
                return
            end
            
            % THE MAIN CALL: Begin reading specified log file
            readLog(obj);
            
            % Clear out the (temporary) properties
            obj.log_data = char(0);
            obj.log_data_read_ndx = 0;
            obj.fmt_cell = cell(0);
            obj.fmt_type_mat = [];
        end
        
        function delete(obj)
            % If Ardupilog errors, close the waitbar
            delete(obj.wb_handle);
            % Probably won't ever be open, but try to close the file too, just in case
            if ~isempty(fopen('all')) && any(fopen('all')==obj.fileID)
                fclose(obj.fileID);
            end
        end
        
        function [] = readLog(obj)
        % Open file, read all data, count number of headers = number of messages, process data, close file

            % Open a file at [filePathName filesep fileName]
            [obj.fileID, errmsg] = fopen([obj.filePathName, filesep, obj.fileName], 'r');
            if ~isempty(errmsg) || obj.fileID==-1
                error(errmsg);
            end

            % Define the read-size (inf=read whole file) and read the logfile
            readsize = inf; % Block size to read before performing a count
            obj.log_data = fread(obj.fileID, [1, readsize], '*uchar'); % Read the datafile entirely

            % Close the file
            if fclose(obj.fileID) == 0;
                obj.fileID = -1;
            else
                warn('File not closed successfully')
            end
            
            % Discover the locations of all the messages
            FMTLength = 89;
            FMTIndices = obj.discoverMSG(128,FMTLength);
            % Read the FMT message
            % Generate the index mask which corresponds to the places where
            % FMT information exists
            indices = reshape(ones(length(FMTIndices),1)*(3:(FMTLength-1)) + (ones(length(FMTIndices),1).*FMTIndices')*ones(1,FMTLength-3),[1 length(FMTIndices)*(FMTLength-3)]);
            % Get teh FMT data and reshape it into a Nx86 array
            data = reshape(obj.log_data(indices),[length(FMTIndices) (FMTLength-3)]);
            obj.createLogMsgGroups(data);
            
            % Iterate over all the discovered msgs
            for i=1:length(obj.fmt_cell)
                msgId = obj.fmt_cell{i,1};
                if msgId==128 % Skip re-searching for FMT messages
                    continue;
                end
                msgName = obj.fmt_cell{i,2};
                msgLen = obj.fmt_cell{i,3};
                MSGIndices = obj.discoverMSG(msgId,msgLen);
                if isempty(MSGIndices) % Skip storing non-appearing message types
                    continue;
                end
                indices = reshape(ones(length(MSGIndices),1)*(3:(msgLen-1)) + (ones(length(MSGIndices),1).*MSGIndices')*ones(1,msgLen-3),[1 length(MSGIndices)*(msgLen-3)]);
                data = reshape(obj.log_data(indices),[length(MSGIndices) (msgLen-3)]);
                obj.(msgName).storeData(data);
            end
            
%             % Prompt user to choose how many messages to process, and setup GUI waitbar
%             num_lines = input(sprintf('How many log lines to process? (%d total, press Enter to process all): ', obj.numMsgs));
%             waitbar_max_lines = num_lines;
%             if isempty(num_lines)
%                 num_lines = obj.numMsgs*10; % numMsgs should be accurate, the *10 is "just in case"...
%                 waitbar_max_lines = obj.numMsgs;
%             end
%             obj.wb_handle = waitbar(0, 'Initializing...', ...
%                          'Name', ['Processing log: ', obj.fileName], ...
%                          'CreateCancelBtn', 'setappdata(gcbf, ''cancel_pressed'', 1)');
%             setappdata(obj.wb_handle,'cancel_pressed',0);
% 
%             % Process messages one by one, either creating formats, moving to seen, or appending seen
%             for ctr = 1:num_lines % HGM: Consider replacing for-loop with while loop?
%                 % If another log line exists, process it
%                 if obj.log_data_read_ndx < numel(obj.log_data);
%                     % Check to see if user pressed cancel button
%                     if getappdata(obj.wb_handle, 'cancel_pressed') == 1
%                         disp('Canceled by user')
%                         break
%                     end
%                     % The main call to process a single log line
%                     obj.readLogLine();
%                 else % at end of file
%                     disp('Reached end of log.')
%                     obj.numMsgs = obj.lastLineNum;
%                     break
%                 end
% 
%                 % Display progress for user
%                 if mod(obj.lastLineNum, 1000) == 0 % every 1e3 messages
%                     waitbar(ctr/waitbar_max_lines, obj.wb_handle, sprintf('%d of %d', obj.lastLineNum, waitbar_max_lines));
%                 end
%             end
% 
%             delete(obj.wb_handle);
            
            % Display message on completion
            disp(['Done processing ', num2str(obj.lastLineNum), ' lines.'])
        end
        
        function headerIndices = discoverMSG(obj,msgId,msgLen)
            debug = true;
%             debug = false;
            if debug; fprintf('Searching for msgs with id=%d\n',msgId); end
            % Parses the whole log file and find the indices of all the msgs
            % Cross-references with the length of each message
            
            % Locate all the candidate msgHeader positions
            headerIndices = strfind(obj.log_data, [obj.header msgId]);
            % Locate all the type fields
            logSize = length(obj.log_data);
            overflow = find(headerIndices+msgLen-1>logSize,1,'first'); % Check if the message will not fit in the log
            if ~isempty(overflow)
                headerIndices(overflow:end) = [];
            end

            % Verify that after each msgLen there is a new message
            b1_next_overflow = find((headerIndices+msgLen)>logSize); % Find where there can be no next b1
            b2_next_overflow = find((headerIndices+msgLen+1)>logSize); % Find where there can be no next b2
            b1_next = obj.log_data(headerIndices(setdiff(1:length(headerIndices),b1_next_overflow)) + msgLen);
            b2_next = obj.log_data(headerIndices(setdiff(1:length(headerIndices),b2_next_overflow)) + msgLen + 1);
            b1_next_invalid = find(b1_next~=obj.header(1));
            b2_next_invalid = find(b2_next~=obj.header(2));
            % Remove invalid message indices
            invalid = unique([b1_next_invalid b2_next_invalid]);
            headerIndices(invalid) = [];
        end

        
        function [] = createLogMsgGroups(obj,data)
            for i=1:size(data,1)
                % Process FMT message to create a new dynamic property
                msgData = data(i,:);
                
                newType = double(msgData(1));
                newLen = double(msgData(2)); % Note: this is header+ID+dataLen = length(header)+1+dataLen.
                
                newName = char(trimTail(msgData(3:6)));
                newFmt = char(trimTail(msgData(7:22)));
                newLabels = char(trimTail(msgData(23:86)));
                
                % Create dynamic property of Ardupilog with newName
                addprop(obj, newName);
                % Instantiate LogMsgGroup class named newName
                obj.(newName) = LogMsgGroup();
                % Process FMT data
                obj.(newName).storeFormat(newType, newLen, newFmt, newLabels);
                
                % Add to obj.fmt_cell and obj.fmt_type_mat (for increased speed)
                obj.fmt_cell = [obj.fmt_cell; {newType, newName, newLen}];
                obj.fmt_type_mat = [obj.fmt_type_mat; newType];
                
            end
            % msgName needs to be FMT
            fmt_ndx = find(obj.fmt_type_mat == 128);
            FMTName = obj.fmt_cell{fmt_ndx, 2};
            % Store msgData correctly in that LogMsgGroup
            obj.(FMTName).storeData(data);
        end
        
        function [] = readLogLine(obj)
        % Reads a single log line
            % Increment the (internal) log line number
            lineNum = obj.lastLineNum + 1;

            % Read till \xA3,\x95 is found (dec=163,149) and position log_data_read_ndx there
            obj.findMsgStart();

            % Read the header and msgTypeNum
            msgHeaderAndMsgTypeNum = obj.readLogData(length(obj.header)+1);

            if isempty(msgHeaderAndMsgTypeNum)
                % Log had header, but ended there, no msgTypeNum.
                return
            end
                        
            % Read msg id
            msgTypeNum = msgHeaderAndMsgTypeNum(end);

            % Process message based on id
            if (msgTypeNum == 128) % message is FMT
                % Process FMT message to create a new dynamic property
                msgData = obj.readLogData(86);

                if isempty(msgData)
                    % If a full msg doesn't exist
                    return
                end
                
                newType = double(msgData(1));
                newLen = double(msgData(2)); % Note: this is header+ID+dataLen = length(header)+1+dataLen.
                
                newName = char(trimTail(msgData(3:6)));
                newFmt = char(trimTail(msgData(7:22)));
                newLabels = char(trimTail(msgData(23:86)));

                % Create dynamic property of Ardupilog with newName
                addprop(obj, newName);
                % Instantiate LogMsgGroup class named newName
                obj.(newName) = LogMsgGroup();
                % Process FMT data
                obj.(newName).storeFormat(newType, newLen, newFmt, newLabels);
                
                % Add to obj.fmt_cell and obj.fmt_type_mat (for increased speed)
                obj.fmt_cell = [obj.fmt_cell; {newType, newName, newLen}];
                obj.fmt_type_mat = [obj.fmt_type_mat; newType];

                % msgName needs to be FMT
                fmt_ndx = find(obj.fmt_type_mat == 128);
                msgName = obj.fmt_cell{fmt_ndx, 2};
            else % message is not FMT
                % Look up msgTypeNum in known FMT.Type to get msgName
                msgType_ndx = find(obj.fmt_type_mat==msgTypeNum, 1, 'first');
                if isempty(msgType_ndx) % if message type unknown
                    warning(['Unknown message type: num=', num2str(msgTypeNum),...
                             ' line=', num2str(lineNum)]);
                    % Do nothing else, the search for next msg header will trash all the bytes
                    return
                end

                msgName = obj.fmt_cell{msgType_ndx,2};
                msgLength = obj.fmt_cell{msgType_ndx,3};
                msgData = obj.readLogData(msgLength-length(obj.header)-1); % Don't count header or msgTypeNum bytes
                
                if isempty(msgData)
                    % Did not get a complete message. Discard incomplete portion and return
                    return
                end
            end % end special processing of FMT vs non-FMT messages

            % Store msgData correctly in that LogMsgGroup
            obj.(msgName).storeMsg(lineNum, msgData);
                
            % Update lastLineNum to indicate log line processed
            obj.lastLineNum = lineNum;
        end
            
        function [] = findMsgStart(obj)
        % Read bytes from the file till the message-start character is found (dec=163,hex=A3).
        % (Leave read_ndx pointing BEFORE the header.)
            
            if all(obj.log_data((1:length(obj.header))+obj.log_data_read_ndx) == obj.header)
                % Header is next set of bytes, don't trash anything, and continue
            elseif (numel(obj.log_data) - obj.log_data_read_ndx) < length(obj.header)
                % Log ends mid-header. No need to warn user, just read incomplete bit and exit silently
                nbytes_remaining = length(obj.log_data)-obj.log_data_read_ndx;
                trash_silent_bytes = obj.readLogData(nbytes_remaining);
            else
                % Header is NOT next 2 bytes... something went wrong.
                warning(['something went wrong, either in the log '...
                         'formation or the log processing. ' ...
                         'Line# ', num2str(obj.lastLineNum), ' ended '...
                         'without a header beginning a new message'])
                hdr_find = strfind(obj.log_data((obj.log_data_read_ndx+1):end), obj.header);
                if isempty(hdr_find)
                    disp('No more headers exist in log')
                    % There are no more valid headers in the log, it is probably done
                    % Trash rest of log and move read_ndx to end, signaling finish
                    nbytes_remaining = length(obj.log_data)-obj.log_data_read_ndx;
                    trash_bytes = obj.readLogData(nbytes_remaining);
                else
                    % Trash part of log and resume
                    num_to_trash = hdr_find(1)-1;
                    trash_bytes = obj.readLogData(num_to_trash);
                end
                disp('Trashing unrecognized/incomplete bytes from log! hex values are:')
                disp(dec2hex(trash_bytes,2))
                disp('Continuing with next message...')
            end
        end
        
        function data = readLogData(obj, index, nbytes)
        % Safely read nbytes of data from obj.log_data, updating the log_data_read_ndx too
            bytes_remaining = length(obj.log_data) - index;
            if bytes_remaining < nbytes
                % Not enough log left, return empty and move read_ndx to end of log
                data = [];
            else
                data = obj.log_data((index-1)+(1:nbytes));
            end
        end
    end %methods
end %classdef Ardupilog

function string = trimTail(string)
% Remove any trailing space (zero-chars)
    while string(end)==0
        string(end) = [];
    end
end